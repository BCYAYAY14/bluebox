import Foundation
import Testing
@testable import Features

/// The updater's steps, with GitHub, the download, the checksum and the
/// installer helper replaced: what each state is, what moves it on, and that
/// a failure or Cancel leaves a readable reason and nothing installed.
@MainActor @Suite struct AppUpdaterTests {
    /// What the fake world did, and the knobs a test turns.
    final class World: @unchecked Sendable {
        var latest: Result<AvailableUpdate?, Error> = .success(nil)
        var latestCalls = 0
        var downloadedFrom: URL?
        var progress: [(Int64, Int64?)] = []
        /// How long each progress report comes after the last.
        var progressDelay: TimeInterval = 0
        /// The progress the state showed after each report.
        var shownProgress: [DownloadProgress] = []
        /// Holds the download until cancelled.
        var downloadWaits = false
        var downloadError: Error?
        var verifyError: Error?
        var verified: (URL, String?)?
        var installMessage: String?
        var installed: (URL, String?)?
        var quits = 0
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        weak var updater: AppUpdater?
        /// The states seen as each step started.
        var states: [AppUpdater.State] = []
        let file = FileManager.default.temporaryDirectory.appending(path: "bluebox-update-test-\(UUID().uuidString).dmg")
    }

    let world = World()
    let defaults = UserDefaults(suiteName: "updater.\(UUID().uuidString)")!

    func makeUpdater() -> AppUpdater {
        let world = world
        let client = UpdateClient(
            latest: {
                world.latestCalls += 1
                return try world.latest.get()
            },
            download: { url, progress in
                world.downloadedFrom = url
                await MainActor.run { world.states.append(world.updater!.state) }
                if let error = world.downloadError { throw error }
                for (received, expected) in world.progress {
                    world.time += world.progressDelay
                    progress(received, expected)
                    // The report hops to the main actor; wait until it shows.
                    for _ in 0..<1000 {
                        let shown = await MainActor.run { () -> DownloadProgress? in
                            if case .downloading(_, let p) = world.updater!.state, p.received == received { return p }
                            return nil
                        }
                        if let shown { world.shownProgress.append(shown); break }
                        await Task.yield()
                    }
                }
                if world.downloadWaits { try await Task.sleep(for: .seconds(60)) }
                FileManager.default.createFile(atPath: world.file.path, contents: Data("dmg".utf8))
                return world.file
            },
            verify: { file, digest in
                await MainActor.run { world.states.append(world.updater!.state) }
                world.verified = (file, digest)
                if let error = world.verifyError { throw error }
            },
            install: { file, digest in
                await MainActor.run { world.states.append(world.updater!.state) }
                world.installed = (file, digest)
                return world.installMessage
            },
            quit: { world.quits += 1 })
        let updater = AppUpdater(client: client, defaults: defaults, now: { world.time })
        world.updater = updater
        return updater
    }

    static let update = AvailableUpdate(
        version: "1.0.15", page: URL(string: "https://github.com/BCYAYAY14/bluebox/releases/tag/ipa-1.0.15")!,
        macDMG: URL(string: "https://github.com/BCYAYAY14/bluebox/releases/download/ipa-1.0.15/Bluebox-mac.dmg")!,
        macDMGDigest: "sha256:" + String(repeating: "ab", count: 32), macDMGSize: 100,
        notes: "### Player\n- Faster subtitles.\n", published: nil)

    // MARK: Checking

    @Test func upToDateRemembersWhenItChecked() async {
        let updater = makeUpdater()
        #expect(updater.state == .idle)
        await updater.check(userInitiated: true)
        #expect(updater.state == .upToDate)
        #expect(updater.lastChecked == world.time)
        #expect(defaults.object(forKey: AppUpdater.lastCheckKey) as? Date == world.time)
        // A new launch still knows.
        #expect(makeUpdater().lastChecked == world.time)
    }

    @Test func anUpdateFoundIsAvailableAndUnseenUntilAboutShowsIt() async {
        world.latest = .success(Self.update)
        let updater = makeUpdater()
        await updater.check(userInitiated: false)
        #expect(updater.state == .available(Self.update))
        #expect(updater.update == Self.update)
        #expect(updater.hasUnseenUpdate)
        updater.markSeen()
        #expect(!updater.hasUnseenUpdate)
        // Seen stays seen after relaunching…
        let again = makeUpdater()
        await again.check(userInitiated: false)
        #expect(!again.hasUnseenUpdate)
        // …until there's a newer version.
        var newer = Self.update
        newer.version = "1.0.16"
        world.latest = .success(newer)
        await again.check(userInitiated: true)
        #expect(again.hasUnseenUpdate)
    }

    @Test func aCheckYouAskedForThatFailsSaysSo() async {
        world.latest = .failure(URLError(.notConnectedToInternet))
        let updater = makeUpdater()
        await updater.check(userInitiated: true)
        guard case .checkFailed(let message) = updater.state else { Issue.record("\(updater.state)"); return }
        #expect(message.contains("GitHub"))
        #expect(updater.lastChecked == nil)
    }

    @Test func theDailyCheckFailingQuietlyLeavesThingsAsTheyWere() async {
        world.latest = .success(nil)
        let updater = makeUpdater()
        await updater.check(userInitiated: true)
        world.latest = .failure(URLError(.timedOut))
        await updater.check(userInitiated: false)
        #expect(updater.state == .upToDate)
    }

    @Test func theDailyCheckRunsOncePerDay() async {
        let updater = makeUpdater()
        await updater.checkIfDue(at: world.time)
        #expect(world.latestCalls == 1)
        await updater.checkIfDue(at: world.time.addingTimeInterval(3600))
        #expect(world.latestCalls == 1)
        await updater.checkIfDue(at: world.time.addingTimeInterval(25 * 3600))
        #expect(world.latestCalls == 2)
    }

    // MARK: Installing

    @Test func installDownloadsChecksInstallsThenQuits() async {
        world.latest = .success(Self.update)
        let updater = makeUpdater()
        await updater.check(userInitiated: true)
        await updater.install(Self.update)
        #expect(world.downloadedFrom == Self.update.macDMG)
        #expect(world.states == [
            .downloading(Self.update, DownloadProgress(received: 0, expected: 100)),
            .verifying(Self.update),
            .installing(Self.update),
        ])
        #expect(world.verified?.0 == world.file)
        #expect(world.verified?.1 == Self.update.macDMGDigest)
        #expect(world.installed?.1 == Self.update.macDMGDigest)
        #expect(world.quits == 1)
        #expect(updater.state == .installing(Self.update))
    }

    @Test func downloadProgressShowsBytesAndTimeLeft() async throws {
        world.progress = [(25, 100)]
        world.progressDelay = 10  // 25 bytes in 10 s: 75 more take 30 s
        let updater = makeUpdater()
        await updater.install(Self.update)
        #expect(world.shownProgress.count == 1)
        let p = try #require(world.shownProgress.last)
        #expect(p.fraction == 0.25)
        #expect(p.secondsLeft == 30)
        #expect(UpdateCard.downloaded(p).hasSuffix("about 30 seconds left"))
    }

    @Test func aChecksumThatDoesntMatchStopsBeforeInstalling() async {
        world.verifyError = UpdateFailure(message: "The download doesn't match GitHub's checksum, so it wasn't installed. Nothing was changed.")
        let updater = makeUpdater()
        await updater.install(Self.update)
        #expect(updater.state == .installFailed(Self.update, "The download doesn't match GitHub's checksum, so it wasn't installed. Nothing was changed."))
        #expect(world.installed == nil)
        #expect(world.quits == 0)
        #expect(!FileManager.default.fileExists(atPath: world.file.path))
    }

    @Test func theHelperRefusingSaysWhyAndDoesntQuit() async {
        world.installMessage = "The new copy isn't signed with Bluebox's release certificate. Nothing was changed."
        let updater = makeUpdater()
        await updater.install(Self.update)
        #expect(updater.state == .installFailed(Self.update, "The new copy isn't signed with Bluebox's release certificate. Nothing was changed."))
        #expect(world.quits == 0)
        #expect(!FileManager.default.fileExists(atPath: world.file.path))
        // Try Again starts over.
        world.installMessage = nil
        await updater.install(Self.update)
        #expect(world.quits == 1)
    }

    @Test func aDownloadThatFailsSaysWhy() async {
        world.downloadError = URLError(.networkConnectionLost)
        let updater = makeUpdater()
        await updater.install(Self.update)
        guard case .installFailed(_, let message) = updater.state else { Issue.record("\(updater.state)"); return }
        #expect(message.hasPrefix("The download didn't finish"))
        #expect(world.verified == nil)
    }

    @Test func cancelStopsTheDownloadAndGoesBack() async {
        world.downloadWaits = true
        let updater = makeUpdater()
        let install = Task { await updater.install(Self.update) }
        while world.downloadedFrom == nil { await Task.yield() }
        #expect(updater.isBusy)
        updater.cancel()
        await install.value
        #expect(updater.state == .available(Self.update))
        #expect(world.verified == nil)
        #expect(world.installed == nil)
    }

    @Test func nothingElseStartsWhileItsBusy() async {
        world.downloadWaits = true
        world.latest = .success(nil)
        let updater = makeUpdater()
        let install = Task { await updater.install(Self.update) }
        while world.downloadedFrom == nil { await Task.yield() }
        await updater.check(userInitiated: true)
        #expect(world.latestCalls == 0)
        if case .downloading = updater.state {} else { Issue.record("\(updater.state)") }
        updater.cancel()
        await install.value
    }

    @Test func aReleaseWithoutAMacDownloadSaysSo() async {
        var update = Self.update
        update.macDMG = nil
        let updater = makeUpdater()
        await updater.install(update)
        guard case .installFailed(_, let message) = updater.state else { Issue.record("\(updater.state)"); return }
        #expect(message.contains("no Mac download"))
        #expect(world.downloadedFrom == nil)
    }

    // MARK: GitHub and the notes

    @Test func readsTheReleaseGitHubReturns() throws {
        let json = """
        {"tag_name": "ipa-1.0.15", "html_url": "https://github.com/BCYAYAY14/bluebox/releases/tag/ipa-1.0.15",
         "published_at": "2026-10-30T12:00:00Z", "body": "### Fixed\\n- A thing.",
         "assets": [{"name": "Bluebox.ipa", "browser_download_url": "https://example.com/a.ipa", "size": 5},
                    {"name": "Bluebox-mac.dmg", "browser_download_url": "https://example.com/b.dmg", "size": 74868736,
                     "digest": "sha256:\(String(repeating: "0", count: 64))"}]}
        """
        let update = try #require(try AppUpdater.parse(Data(json.utf8), current: "1.0.14"))
        #expect(update.version == "1.0.15")
        #expect(update.macDMG == URL(string: "https://example.com/b.dmg"))
        #expect(update.macDMGSize == 74_868_736)
        #expect(update.macDMGDigest?.hasPrefix("sha256:") == true)
        #expect(update.notes == "### Fixed\n- A thing.")
        #expect(update.published == Date(timeIntervalSince1970: 1_793_361_600))
        #expect(try AppUpdater.parse(Data(json.utf8), current: "1.0.15") == nil)
    }

    @Test func versionsCompareByNumber() {
        #expect(AppUpdater.isNewer("1.0.10", than: "1.0.9"))
        #expect(!AppUpdater.isNewer("1.0.9", than: "1.0.10"))
        #expect(!AppUpdater.isNewer("1.0.15", than: "dev"))
    }

    @Test func releaseNotesSplitIntoHeadingsAndPoints() {
        let notes = ReleaseNotes(markdown: """
        ### Player
        - Subtitles switch without a rebuffer.
        - **Bold** stays inline.

        ### Fixed
        - The updater quits.

        [Everything that changed in 1.0.15](https://github.com/BCYAYAY14/bluebox/blob/main/CHANGELOG.md#1015)
        """)
        #expect(notes.sections == [
            .init(title: "Player", points: ["Subtitles switch without a rebuffer.", "**Bold** stays inline."]),
            .init(title: "Fixed", points: ["The updater quits."]),
        ])
        #expect(notes.fullNotes == URL(string: "https://github.com/BCYAYAY14/bluebox/blob/main/CHANGELOG.md#1015"))
        #expect(ReleaseNotes(markdown: "").isEmpty)
        #expect(ReleaseNotes(markdown: "Just a line.").sections == [.init(title: nil, points: ["Just a line."])])
    }

    @Test func whenItLastCheckedReadsNaturally() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_793_361_600)
        #expect(UpdateCard.checked(now.addingTimeInterval(-60), now: now, calendar: calendar).hasPrefix("today at "))
        #expect(UpdateCard.checked(now.addingTimeInterval(-86_400), now: now, calendar: calendar).hasPrefix("yesterday at "))
        #expect(UpdateCard.checked(now.addingTimeInterval(-5 * 86_400), now: now, calendar: calendar).contains(" at "))
    }
}
