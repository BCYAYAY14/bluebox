import Foundation
import Observation
#if os(macOS)
import AppKit
import UpdateVerification
#endif

/// A newer Bluebox on GitHub (BCYAYAY14/bluebox's latest release).
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    /// The release's page, for the notes and the downloads.
    public var page: URL
    /// Bluebox-mac.dmg, when the release has one.
    public var macDMG: URL?
    /// GitHub's `sha256:<hex>` digest of it, which the updater checks.
    public var macDMGDigest: String?
    /// Its size in bytes, as GitHub lists it.
    public var macDMGSize: Int64?
    /// The release's notes: the CHANGELOG section publish.sh puts there (Markdown).
    public var notes: String = ""
    public var published: Date?
}

/// How far the download has got.
public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var expected: Int64?
    /// From the rate so far, once there's enough to go on.
    public var secondsLeft: Double?

    public var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}

/// What the updater needs from the outside world, so its steps can be tested.
struct UpdateClient: Sendable {
    /// GitHub's latest release, or nil when it isn't newer than this copy.
    var latest: @Sendable () async throws -> AvailableUpdate?
    /// Downloads the DMG to a file, reporting bytes. Throws CancellationError when cancelled.
    var download: @Sendable (URL, _ progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
    /// Checks the file against GitHub's digest; throws `UpdateFailure` with a readable reason.
    var verify: @Sendable (URL, String?) async throws -> Void
    /// Hands the file to the installer helper: nil once installed, or what went wrong.
    var install: @Sendable (URL, String?) async -> String?
    /// Quits, so the helper can open the new copy.
    var quit: @MainActor @Sendable () -> Void
}

struct UpdateFailure: Error, Equatable { let message: String }

/// Checks GitHub for a newer release (by itself once a day, from Settings ›
/// About, and from Bluebox › Check for Updates… on a Mac) and, on a Mac,
/// downloads, checks and installs it. Every step shows in place on
/// Settings › About (`UpdateCard`); nothing here presents an alert. An update
/// found by the daily check shows as a dot on the profile button until About
/// has been seen. iPhone and iPad are sideloaded, so they only check: the
/// update comes through FlareStore (or AltStore, SideStore, Feather).
@Observable @MainActor
public final class AppUpdater {
    public static let shared = AppUpdater(client: .live, defaults: .standard)

    public enum State: Equatable {
        /// Not checked since launch.
        case idle
        case checking
        case upToDate
        /// GitHub couldn't be reached when asked.
        case checkFailed(String)
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, DownloadProgress)
        /// The download against GitHub's digest.
        case verifying(AvailableUpdate)
        /// The helper checks the signature against Bluebox's release
        /// certificate and swaps the app in; then Bluebox quits.
        case installing(AvailableUpdate)
        /// Nothing was changed; the reason is readable.
        case installFailed(AvailableUpdate, String)
    }

    public private(set) var state: State = .idle
    /// When GitHub last answered.
    public private(set) var lastChecked: Date?
    /// The version whose card has been seen on Settings › About.
    private(set) var seenVersion: String?

    private let client: UpdateClient
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var installTask: Task<Void, Never>?

    static let repository = "BCYAYAY14/bluebox"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    /// The FlareStore / AltStore source Bluebox's IPA comes from (scripts/ipa-source.py).
    static let ipaSource = URL(string: "https://raw.githubusercontent.com/\(repository)/main/source.json")!
    static let lastCheckKey = "bluebox.update.lastCheck"
    static let seenKey = "bluebox.update.seenVersion"

    init(client: UpdateClient, defaults: UserDefaults, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.defaults = defaults
        self.now = now
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
        seenVersion = defaults.string(forKey: Self.seenKey)
    }

    /// The update the current state is about, if any.
    public var update: AvailableUpdate? {
        switch state {
        case .available(let u), .downloading(let u, _), .verifying(let u), .installing(let u), .installFailed(let u, _): u
        case .idle, .checking, .upToDate, .checkFailed: nil
        }
    }

    /// Checking, downloading, verifying or installing: buttons wait.
    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    /// An update About hasn't shown yet: the dot on the profile button and in the sidebar.
    public var hasUnseenUpdate: Bool {
        guard let update else { return false }
        return update.version != seenVersion
    }

    /// About showed the update: the dots go until the next version.
    func markSeen() {
        guard let update, update.version != seenVersion else { return }
        seenVersion = update.version
        defaults.set(update.version, forKey: Self.seenKey)
    }

    #if DEBUG
    /// Snapshots and previews: show a state without GitHub.
    func preview(_ state: State, lastChecked: Date? = nil) {
        self.state = state
        self.lastChecked = lastChecked
    }
    #endif

    /// At launch: at most once a day, and quiet (a dot, never a prompt).
    public func checkIfDue() async {
        #if DEBUG && os(macOS)
        // Checking the installer: `-install-latest-update` installs GitHub's latest at launch.
        if ProcessInfo.processInfo.arguments.contains("-install-latest-update"), let update = try? await client.latest() {
            await install(update)
            return
        }
        #endif
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") == false else { return }
        await checkIfDue(at: now())
    }

    func checkIfDue(at date: Date) async {
        guard date.timeIntervalSince(lastChecked ?? .distantPast) > 24 * 3600 else { return }
        await check(userInitiated: false)
    }

    /// Asks GitHub. A check you didn't ask for that fails leaves things as they were.
    public func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let before = state
        state = .checking
        do {
            let found = try await client.latest()
            lastChecked = now()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            state = found.map(State.available) ?? .upToDate
        } catch {
            state = userInitiated ? .checkFailed("GitHub didn't answer. Check your connection and try again.") : before
        }
    }

    /// Mac: downloads the update, checks it against GitHub's digest, and has
    /// the helper check its signature and install it; then quits, and the new
    /// one opens by itself. Each step shows in `state`; Cancel works until
    /// installing starts. Returns when it's done, failed or cancelled.
    public func install(_ update: AvailableUpdate) async {
        guard !isBusy else { return }
        let task = Task { await run(update) }
        installTask = task
        await task.value
        if installTask == task { installTask = nil }
    }

    /// Stops a download or check in progress. Installing can't be stopped.
    public func cancel() {
        switch state {
        case .downloading, .verifying: installTask?.cancel()
        default: break
        }
    }

    private func run(_ update: AvailableUpdate) async {
        guard let dmg = update.macDMG else {
            state = .installFailed(update, "This release has no Mac download. Download Bluebox from GitHub.")
            return
        }
        let started = now()
        state = .downloading(update, DownloadProgress(received: 0, expected: update.macDMGSize))
        let file: URL
        do {
            file = try await client.download(dmg) { [weak self] received, expected in
                Task { @MainActor in self?.downloaded(received, of: expected ?? update.macDMGSize, since: started, for: update) }
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .available(update)
            } else {
                state = .installFailed(update, "The download didn't finish: \(Self.sentence(error.localizedDescription)) Nothing was changed.")
            }
            return
        }
        guard !Task.isCancelled else { return discard(file, back: update) }
        state = .verifying(update)
        do {
            try await client.verify(file, update.macDMGDigest)
        } catch {
            try? FileManager.default.removeItem(at: file)
            state = .installFailed(update, (error as? UpdateFailure)?.message ?? Self.sentence(error.localizedDescription))
            return
        }
        guard !Task.isCancelled else { return discard(file, back: update) }
        state = .installing(update)
        if let message = await client.install(file, update.macDMGDigest) {
            try? FileManager.default.removeItem(at: file)
            state = .installFailed(update, message)
        } else {
            client.quit()  // the updater opens the new Bluebox once this one has quit
        }
    }

    private func discard(_ file: URL, back update: AvailableUpdate) {
        try? FileManager.default.removeItem(at: file)
        state = .available(update)
    }

    private func downloaded(_ received: Int64, of expected: Int64?, since started: Date, for update: AvailableUpdate) {
        guard case .downloading(let current, _) = state, current == update else { return }
        var progress = DownloadProgress(received: received, expected: expected)
        let elapsed = now().timeIntervalSince(started)
        if let expected, received > 0, elapsed > 2 {
            progress.secondsLeft = max(0, Double(expected - received) / (Double(received) / elapsed))
        }
        state = .downloading(update, progress)
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    // MARK: GitHub

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String?; let size: Int64? }
        let tag_name: String
        let html_url: URL
        let body: String?
        let published_at: Date?
        let assets: [Asset]
    }

    static func latest() async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data, current: AppVersion.marketing)
    }

    /// The release GitHub returned, if it's newer than `current`.
    static func parse(_ data: Data, current: String) throws -> AvailableUpdate? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Release.self, from: data)
        let version = release.tag_name.replacingOccurrences(of: "ipa-", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard isNewer(version, than: current) else { return nil }
        let dmg = release.assets.first { $0.name == "Bluebox-mac.dmg" }
        return AvailableUpdate(version: version, page: release.html_url, macDMG: dmg?.browser_download_url,
                               macDMGDigest: dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? $0 : nil },
                               macDMGSize: dmg?.size, notes: release.body ?? "", published: release.published_at)
    }

    /// "1.0.10" is newer than "1.0.9". A build without a version ("dev") is never behind.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").map { Int($0) }
            return p.contains(nil) || p.isEmpty ? nil : p.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

extension UpdateClient {
    static var live: UpdateClient {
        #if os(macOS)
        UpdateClient(
            latest: { try await AppUpdater.latest() },
            download: { url, progress in try await UpdateDownload.run(url, progress: progress) },
            verify: { file, digest in
                try await Task.detached(priority: .userInitiated) {
                    do {
                        try UpdateVerification.verifyDigest(of: file, expected: digest)
                    } catch let failure as UpdateVerification.Failure {
                        throw UpdateFailure(message: failure.message + " Nothing was changed.")
                    }
                }.value
            },
            install: { file, digest in await UpdateInstaller.install(dmgFile: file, sha256: digest) },
            quit: { NSApp.quitFromTask() })
        #else
        // iPhone and iPad only check; the update comes through FlareStore.
        UpdateClient(
            latest: { try await AppUpdater.latest() },
            download: { _, _ in throw UpdateFailure(message: "Bluebox can't install updates itself on iPhone and iPad.") },
            verify: { _, _ in },
            install: { _, _ in "Bluebox can't install updates itself on iPhone and iPad." },
            quit: {})
        #endif
    }
}

// MARK: - Release notes

/// A release's notes as publish.sh writes them (scripts/release-notes.py):
/// `### Heading` sections of `- ` points, then a link to the full entry.
struct ReleaseNotes: Equatable {
    struct Section: Equatable {
        var title: String?
        var points: [String]
    }
    var sections: [Section]
    /// "Everything that changed in 1.0.15" on GitHub.
    var fullNotes: URL?

    init(markdown: String) {
        var sections: [Section] = []
        var link: URL?
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                sections.append(Section(title: line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), points: []))
            } else if let url = Self.onlyLink(line) {
                link = url
            } else {
                let point = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
                if sections.isEmpty { sections.append(Section(title: nil, points: [])) }
                sections[sections.count - 1].points.append(point)
            }
        }
        self.sections = sections.filter { !$0.points.isEmpty }
        fullNotes = link
    }

    var isEmpty: Bool { sections.isEmpty }

    /// `[text](url)` alone on its line.
    private static func onlyLink(_ line: String) -> URL? {
        guard line.hasPrefix("["), line.hasSuffix(")"), let mid = line.range(of: "](") else { return nil }
        return URL(string: String(line[mid.upperBound..<line.index(before: line.endIndex)]))
    }
}

#if os(macOS)
/// Must match the protocol in Apps/macOSUpdater/main.swift.
@objc(BlueboxUpdaterProtocol) protocol BlueboxUpdaterProtocol {
    func install(dmg: FileHandle, sha256: String?, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

/// Downloads Bluebox-mac.dmg into this app's temporary folder, reporting
/// bytes. Gives up after 30 s without data (or 10 minutes in all); cancelling
/// the task stops it.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let destination: URL
    private var lastReported: Int64 = -1

    private init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination; self.progress = progress
    }

    static func run(_ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "Bluebox-update.dmg")
        try? FileManager.default.removeItem(at: destination)
        let download = UpdateDownload(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                download.lock.withLock { download.continuation = c }
                if Task.isCancelled { download.finish(.failure(CancellationError())) } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
            download.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.withLock {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        // About every 1% (or 512 KB when the size isn't known).
        let step = max((expected ?? 0) / 100, 512 * 1024)
        let report = lock.withLock { () -> Bool in
            guard totalBytesWritten - lastReported >= step || totalBytesWritten == expected else { return false }
            lastReported = totalBytesWritten
            return true
        }
        if report { progress(totalBytesWritten, expected) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(URLError(.badServerResponse))); return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

/// Talks to BlueboxUpdater.xpc, which runs outside the sandbox: it checks the
/// downloaded DMG against GitHub's digest, mounts it, checks the new
/// Bluebox.app is signed by Bluebox's release certificate (UpdateVerification),
/// swaps it in (the old one goes to the Trash), and opens it once this one quits.
/// The DMG goes over as an open file: macOS keeps other processes (the
/// updater's hdiutil among them) out of this app's container, so a path won't do.
enum UpdateInstaller {
    /// Nil when installed (quit to finish), or what went wrong. Gives up after `timeout`.
    static func install(dmgFile: URL, sha256: String?, timeout: Duration = .seconds(240)) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: dmgFile) else { return "The download is missing." }
        defer { try? handle.close() }
        let connection = NSXPCConnection(serviceName: "app.bluebox.Bluebox.mac.Updater")
        connection.remoteObjectInterface = NSXPCInterface(with: BlueboxUpdaterProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let once = Once(done)
            Task {
                try? await Task.sleep(for: timeout)
                once.resume("Installing took too long, so Bluebox stopped waiting. Nothing was changed. Try again, or download Bluebox from GitHub.")
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume("The updater didn't start: \(error.localizedDescription)")
            } as? BlueboxUpdaterProtocol
            guard let proxy else { once.resume("The updater is missing from this copy of Bluebox."); return }
            proxy.install(dmg: handle, sha256: sha256, appPath: path, relaunchAfter: pid) { once.resume($0) }
        }
    }

    /// The reply and the error handler can both fire; only the first counts.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ c: CheckedContinuation<String?, Never>) { continuation = c }
        func resume(_ value: String?) {
            lock.withLock {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
    }
}
#endif
