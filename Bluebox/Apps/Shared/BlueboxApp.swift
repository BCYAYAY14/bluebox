import Features
import SwiftUI
import UserNotifications
#if os(iOS)
import AVFoundation
import UIKit

/// Hands iOS's background-download completion handler to the download manager.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Resumes torrent downloads while the device charges (must register before launch ends).
        AppModel.registerBackgroundDownloadTask()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let done = completionHandler
        if !AppModel.handleBackgroundDownloadEvents(identifier: identifier, completion: { done() }) { completionHandler() }
    }

    /// iPhone: portrait, except landscape while the player is up (PlayerOrientation).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientation.supported
    }
}
#elseif os(macOS)
import AppKit

/// Quits in order: the playing position is saved and libtorrent stops its
/// threads before the process exits (otherwise quitting after a torrent
/// stream could crash in libtorrent's static destructors).
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    /// Closing the window leaves Bluebox running, so downloads carry on; the
    /// menu bar item shows them, and the Dock icon or ⌘0 brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !terminating else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

@main
struct BlueboxApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model: AppModel?
    @State private var launchError: String?
    /// A link opened before the library finished loading.
    @State private var pendingURL: URL?
    /// A Handoff that arrived before the library finished opening.
    @State private var pendingHandoff: NSUserActivity?
    /// Home is built only once the launch ident's sweep has played: building
    /// it stalls the main thread, which would freeze the sweep.
    @State private var introHoldsContent = LaunchIntroOverlay.playsOnLaunch
    #if os(macOS)
    @AppStorage(MenuBarDownloads.alwaysShowKey) private var menuBarAlwaysShown = false
    #endif

    init() {
        // Settings › Storage › Erase All Data quit the app to do this here,
        // before anything opens the library.
        EraseAllData.runIfPending()
        #if os(iOS)
        // Playback category so audio continues with the ringer switch off and PiP works.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
        // New-episode alerts: show them while open, and open the episode when tapped.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            Group {
                if let model, !introHoldsContent {
                    RootView().accountLinkBanner().mobileDataPlayWarning().environment(model)
                        .modifier(ToastHost(model: model))
                } else if let launchError {
                    ContentUnavailableView("Bluebox couldn't open its library", systemImage: "exclamationmark.triangle",
                                           description: Text(launchError))
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            .modifier(LaunchIntroOverlay(holdingContent: $introHoldsContent,
                                         contentReady: model != nil || launchError != nil))
            .preferredColorScheme(.dark)
            .task { await launch() }
            .updatePrompt()
            // Links from another device (bluebox://connect…) and old sign-in links (bluebox://auth-callback…)
            .onOpenURL { url in
                if let model { model.handleOpenURL(url) } else { pendingURL = url }
            }
            // Handoff: open what the other device was playing, at that second.
            .onContinueUserActivity(WatchActivityPayload.activityType) { activity in
                guard let model else { pendingHandoff = activity; return }
                Task { await model.continueWatching(from: activity) }
            }
            #if os(macOS)
            .frame(minWidth: 820, minHeight: 560)
            // Open links in the existing window instead of a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            #endif
        }
        #if os(iOS)
        // Checks followed shows for new episodes (Info.plist › BGTaskSchedulerPermittedIdentifiers).
        .backgroundTask(.appRefresh(AppModel.episodeRefreshTaskID)) {
            await AppModel.handleBackgroundRefresh()
        }
        #endif
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        // Always open with the main window, even if it was closed when Bluebox last
        // quit: restoration alone can restore "no windows" and leave only the menu bar.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AboutCommands()
            MainWindowCommands()
            // ⌘W closes the player first, not the whole window under it.
            CommandGroup(before: .saveItem) {
                Button("Close Player") { Task { await model?.closePlayer() } }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model?.activePlayer == nil)
            }
            // ⌃⌘1–4 and the profile list (Features/ProfileCommands.swift).
            ProfileCommands(model: model)
            CommandMenu("Playback") {
                Button(model?.activePlayer?.snapshot.status == .playing ? "Pause" : "Play") {
                    model?.activePlayer?.togglePlayPause()
                }
                .disabled(model?.activePlayer == nil)  // Space works in the player itself
                Button("Next Episode") { Task { await model?.activePlayer?.playNext() } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                    .disabled(model?.activePlayer?.item?.key.episodeNumbers == nil)
                Divider()
                // Also in Settings › Privacy & Features.
                Toggle("Allow Remote Control", isOn: Binding(
                    get: { model?.featureSwitches.allowRemoteControl ?? false },
                    set: { model?.featureSwitches.allowRemoteControl = $0 }))
                    .disabled(model == nil)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            if let model { SettingsView().environment(model) }
        }

        // Downloads in the menu bar while any run (or always, by its checkbox).
        // The setter only writes when the value changes: AppKit reports the item's
        // visibility back on every update, and writing the same value to AppStorage
        // still rebuilt the scene, which reported it again (a main-thread loop).
        MenuBarExtra(isInserted: Binding(
            get: { menuBarAlwaysShown || (model?.activeDownloadCount ?? 0) > 0 },
            set: { if !$0, menuBarAlwaysShown { menuBarAlwaysShown = false } })) {
            if let model { MenuBarContent().environment(model) }
        } label: {
            Image(systemName: "arrow.down.circle")
                .accessibilityLabel("Bluebox Downloads")
        }
        .menuBarExtraStyle(.window)

        // Bluebox › About Bluebox, in place of the stock panel.
        Window("About Bluebox", id: Self.aboutWindowID) {
            AboutWindowView()
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Self.showsAboutOnLaunch ? .presented : .suppressed)
        .defaultPosition(.center)
        .commandsRemoved()

        // About › Acknowledgements and Licence.
        WindowGroup(id: AboutDocument.windowID, for: AboutDocument.self) { $document in
            AboutDocumentView(document: document ?? .acknowledgements)
        }
        .defaultSize(width: 620, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        #endif
    }

    @MainActor
    private func launch() async {
        guard model == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        do {
            // A background refresh may already have opened the library (AppModel.current).
            let m: AppModel
            if args.contains("-ui-testing") {
                m = AppModel.demo(seed: !args.contains("-empty-library"))
            } else if let current = AppModel.current {
                m = current
            } else {
                m = try await AppModel.liveReadingSecrets()
            }
            await m.bootstrap()
            #if DEBUG
            if args.contains("-ui-testing") && args.contains("-seed-screens") { await m.seedScreensForReview() }
            if args.contains("-ui-testing") && args.contains("-seed-profiles") { m.seedProfilesForReview() }
            #endif
            model = m
            #if os(macOS)
            appDelegate.model = m
            #endif
            if let url = pendingURL { pendingURL = nil; m.handleOpenURL(url) }
            if let handoff = pendingHandoff {
                pendingHandoff = nil
                await m.continueWatching(from: handoff)
            }
            #if DEBUG
            await m.runPlayerDebugLaunchArguments(args)  // simulated Handoff, for checking the player
            #endif
        } catch {
            launchError = error.localizedDescription
        }
    }
}

#if os(macOS)
extension BlueboxApp {
    static let mainWindowID = "main"
    static let aboutWindowID = "about"

    /// Debug builds launched with `-show-about` open the About window at once (for screenshots).
    static var showsAboutOnLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-show-about")
        #else
        false
        #endif
    }
}

/// Bluebox › About Bluebox opens Bluebox's own About window (`AboutWindowView`).
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Bluebox") { openWindow(id: BlueboxApp.aboutWindowID) }
            Button("Check for Updates…") { Task { await AppUpdater.shared.check(userInitiated: true) } }
        }
    }
}

/// Window › Bluebox (⌘0): brings the main window back after it was closed,
/// or to the front if it's behind Settings. Without it only the Dock icon could.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Bluebox") { Self.showMainWindow(openWindow) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }

    @MainActor static func showMainWindow(_ openWindow: OpenWindowAction) {
        // A closed window lingers in NSApp.windows; only raise one that's still open.
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(BlueboxApp.mainWindowID) == true && ($0.isVisible || $0.isMiniaturized)
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: BlueboxApp.mainWindowID)
        }
    }
}

/// The menu bar's mini queue. Open Downloads brings the main window back on the Downloads tab.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarDownloadsView {
            NSApp.activate()
            MainWindowCommands.showMainWindow(openWindow)
            model.downloadsOpenRequest += 1
        }
    }
}
#else
extension BlueboxApp {
    static let mainWindowID = "main"
}
#endif
