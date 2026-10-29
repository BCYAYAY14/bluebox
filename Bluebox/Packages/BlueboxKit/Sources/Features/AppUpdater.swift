import DesignSystem
import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A newer Bluebox on GitHub (BCYAYAY14/bluebox's latest release).
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    /// The release's page, for the notes and the downloads.
    public var page: URL
    /// Bluebox-mac.dmg, when the release has one.
    public var macDMG: URL?
}

/// Checks GitHub for a newer release: by itself once a day, or from
/// Settings › About (and Bluebox › Check for Updates… on a Mac). The Mac
/// installs it (`UpdateInstaller`); iPhone and iPad are sideloaded, so they
/// point to wherever Bluebox was installed from.
@Observable @MainActor
public final class AppUpdater {
    public static let shared = AppUpdater()

    public enum State: Equatable {
        case idle, checking, upToDate
        case available(AvailableUpdate)
        /// Bluebox-mac.dmg coming down; the fraction once the size is known.
        case downloading(AvailableUpdate, Double?)
        case installing(AvailableUpdate)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// The prompt over the window: an update found (by itself or when asked),
    /// or "you're up to date" when asked.
    var prompt: Prompt?

    enum Prompt: Identifiable, Equatable {
        case available(AvailableUpdate), upToDate, failed(String)
        var id: String {
            switch self {
            case .available(let u): "available-\(u.version)"
            case .upToDate: "upToDate"
            case .failed(let m): "failed-\(m)"
            }
        }
    }

    static let repository = "BCYAYAY14/bluebox"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let lastCheckKey = "bluebox.update.lastCheck"
    private static let skippedKey = "bluebox.update.skippedVersion"

    /// At launch: at most once a day, and quiet unless there's something new
    /// that wasn't already put off with Later.
    public func checkIfDue() async {
        #if DEBUG && os(macOS)
        // Checking the installer: `-install-latest-update` installs GitHub's latest at launch.
        if ProcessInfo.processInfo.arguments.contains("-install-latest-update"), let update = try? await Self.latest() {
            await install(update)
            return
        }
        #endif
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600, ProcessInfo.processInfo.arguments.contains("-ui-testing") == false else { return }
        await check(userInitiated: false)
    }

    public func check(userInitiated: Bool) async {
        if case .checking = state { return }
        if case .installing = state { return }
        if case .downloading = state { return }
        state = .checking
        do {
            let update = try await Self.latest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if let update {
                state = .available(update)
                if userInitiated || UserDefaults.standard.string(forKey: Self.skippedKey) != update.version {
                    prompt = .available(update)
                }
            } else {
                state = .upToDate
                if userInitiated { prompt = .upToDate }
            }
        } catch {
            state = .failed("Couldn't reach GitHub. Check your connection and try again.")
            if userInitiated { prompt = .failed("Couldn't reach GitHub. Check your connection and try again.") }
        }
    }

    /// Later: no more prompts for this version (Settings › About still has it).
    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version, forKey: Self.skippedKey)
    }

    #if os(macOS)
    /// Downloads and installs the new version, then quits; it opens again by itself.
    public func install(_ update: AvailableUpdate) async {
        guard let dmg = update.macDMG else { NSWorkspace.shared.open(update.page); return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .downloading(update, nil)
        let file: URL
        do {
            file = try await UpdateDownload.run(dmg) { [weak self] fraction in self?.state = .downloading(update, fraction) }
        } catch {
            state = .available(update)
            prompt = .failed("The download didn't finish: \(error.localizedDescription) Try again, or download Bluebox from GitHub.")
            return
        }
        state = .installing(update)
        if let message = await UpdateInstaller.install(dmgFile: file) {
            try? FileManager.default.removeItem(at: file)
            state = .available(update)
            prompt = .failed(message)
        } else {
            NSApp.terminate(nil)  // the updater opens the new Bluebox once this one has quit
        }
    }
    #endif

    // MARK: GitHub

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    static func latest() async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.replacingOccurrences(of: "ipa-", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard isNewer(version, than: AppVersion.marketing) else { return nil }
        return AvailableUpdate(version: version, page: release.html_url,
                               macDMG: release.assets.first { $0.name == "Bluebox-mac.dmg" }?.browser_download_url)
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

#if os(macOS)
/// Must match the protocol in Apps/macOSUpdater/main.swift.
@objc(BlueboxUpdaterProtocol) protocol BlueboxUpdaterProtocol {
    func install(dmgFile: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

/// Downloads Bluebox-mac.dmg into this app's temporary folder, reporting
/// progress. Gives up after 30 s without data (or 10 minutes in all).
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @MainActor (Double) -> Void
    private let destination: URL
    private var lastReported = -1.0

    private init(destination: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.destination = destination; self.progress = progress
    }

    static func run(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "Bluebox-update.dmg")
        try? FileManager.default.removeItem(at: destination)
        let download = UpdateDownload(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            download.lock.withLock { download.continuation = c }
            session.downloadTask(with: url).resume()
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
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let report = lock.withLock { () -> Bool in
            guard fraction - lastReported >= 0.01 else { return false }
            lastReported = fraction
            return true
        }
        if report { Task { @MainActor in progress(fraction) } }
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

/// Talks to BlueboxUpdater.xpc, which runs outside the sandbox: it mounts the
/// downloaded DMG, swaps the new Bluebox.app in, and opens it once this one quits.
enum UpdateInstaller {
    /// Nil when installed (quit to finish), or what went wrong. Gives up after `timeout`.
    static func install(dmgFile: URL, timeout: Duration = .seconds(120)) async -> String? {
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
            proxy.install(dmgFile: dmgFile, appPath: path, relaunchAfter: pid) { once.resume($0) }
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

// MARK: - Prompt

extension View {
    /// The update alert, and the daily check behind it. On the main window.
    public func updatePrompt() -> some View { modifier(UpdatePromptModifier()) }
}

private struct UpdatePromptModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    private var updater: AppUpdater { .shared }

    func body(content: Content) -> some View {
        @Bindable var updater = updater
        content
            .overlay(alignment: .bottom) { UpdateProgressBadge() }
            .task { await updater.checkIfDue() }
            .alert(title(updater.prompt), isPresented: Binding(get: { updater.prompt != nil }, set: { if !$0 { updater.prompt = nil } }),
                   presenting: updater.prompt) { prompt in
                switch prompt {
                case .available(let update):
                    #if os(macOS)
                    Button("Install and Relaunch") { Task { await updater.install(update) } }
                    #else
                    Button("Open GitHub") { openURL(update.page) }
                    #endif
                    Button("Later", role: .cancel) { updater.skip(update) }
                case .upToDate:
                    Button("OK", role: .cancel) {}
                case .failed:
                    Button("Open GitHub") { openURL(AppUpdater.releasesPage) }
                    Button("OK", role: .cancel) {}
                }
            } message: { prompt in
                Text(message(prompt))
            }
    }

    private func title(_ prompt: AppUpdater.Prompt?) -> String {
        switch prompt {
        case .available(let u): "Bluebox \(u.version) is available"
        case .upToDate: "Bluebox is up to date"
        case .failed: "Couldn't update"
        case nil: ""
        }
    }

    private func message(_ prompt: AppUpdater.Prompt) -> String {
        switch prompt {
        case .available:
            #if os(macOS)
            "You have \(AppVersion.marketing). Bluebox downloads the new version, replaces itself and opens again."
            #else
            "You have \(AppVersion.marketing). Bluebox is sideloaded, so update it where you installed it: refresh the Bluebox source in AltStore, SideStore or Feather, or download the new IPA from GitHub."
            #endif
        case .upToDate: "\(AppVersion.marketing) is the newest version."
        case .failed(let m): m
        }
    }
}

/// Over the window while an update downloads and installs, wherever you are.
private struct UpdateProgressBadge: View {
    private var updater: AppUpdater { .shared }

    var body: some View {
        Group {
            switch updater.state {
            case .downloading(let update, let fraction):
                badge("Downloading Bluebox \(update.version)", fraction: fraction ?? 0)
            case .installing(let update):
                badge("Installing Bluebox \(update.version)", fraction: nil)
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updater.state)
    }

    private func badge(_ title: String, fraction: Double?) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)
            if let fraction {
                ProgressView(value: fraction).tint(Palette.brand).frame(width: 120)
                Text("\(Int(fraction * 100))%").font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings › About

/// Settings › About › Updates.
struct UpdateSection: View {
    @Environment(\.openURL) private var openURL
    private var updater: AppUpdater { .shared }

    var body: some View {
        Section {
            switch updater.state {
            case .available(let update):
                LabeledContent("Bluebox \(update.version)", value: "Available")
                #if os(macOS)
                Button("Install and Relaunch") { Task { await updater.install(update) } }
                #else
                Button("Open GitHub") { openURL(update.page) }
                #endif
            case .downloading(let update, let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading Bluebox \(update.version)…")
                    ProgressView(value: fraction ?? 0).tint(Palette.brand)
                }
            case .installing(let update):
                HStack {
                    Text("Installing Bluebox \(update.version)…")
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            default:
                Button {
                    Task { await updater.check(userInitiated: true) }
                } label: {
                    HStack {
                        Text("Check for Updates")
                        Spacer()
                        if updater.state == .checking { ProgressView().controlSize(.small) }
                        else if updater.state == .upToDate { Text("Up to Date").foregroundStyle(Palette.textSecondary) }
                    }
                }
                .disabled(updater.state == .checking)
                .settingsRow("Check for Updates")
            }
        } header: {
            Text("Updates")
        } footer: {
            #if os(macOS)
            Text("Bluebox checks GitHub once a day and asks before installing.")
            #else
            if case .failed(let m) = updater.state { Text(m) } else {
                Text("Bluebox checks GitHub once a day. It's sideloaded, so updates install where you got it: AltStore, SideStore or Feather.")
            }
            #endif
        }
    }
}
