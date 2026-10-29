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
        state = .installing(update)
        if let message = await UpdateInstaller.install(dmg: dmg) {
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
    func install(dmg: URL, appPath: String, relaunchAfter pid: Int32, reply: @escaping (String?) -> Void)
}

/// Talks to BlueboxUpdater.xpc, which runs outside the sandbox: it downloads
/// the DMG, swaps the new Bluebox.app in, and opens it once this one quits.
enum UpdateInstaller {
    /// Nil when installed (quit to finish), or what went wrong.
    static func install(dmg: URL) async -> String? {
        let connection = NSXPCConnection(serviceName: "app.bluebox.Bluebox.mac.Updater")
        connection.remoteObjectInterface = NSXPCInterface(with: BlueboxUpdaterProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let once = Once(done)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume("The updater didn't start: \(error.localizedDescription)")
            } as? BlueboxUpdaterProtocol
            guard let proxy else { once.resume("The updater is missing from this copy of Bluebox."); return }
            proxy.install(dmg: dmg, appPath: path, relaunchAfter: pid) { once.resume($0) }
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
