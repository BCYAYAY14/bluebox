import Domain
import Foundation
import Persistence
#if os(macOS)
import AppKit
#endif

extension AppModel {
    /// Settings › Storage › Clear Search History: every profile's recent
    /// searches on this device, including profiles since removed.
    func clearSearchHistory() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("bluebox.memory.")
            && (key.hasSuffix(".\(RecentSearches.memoryKey)") || key.hasSuffix(".\(RecentSearches.oldMemoryKey)")) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "bluebox.recentSearches")
        searchHistoryRevision += 1
    }

    /// Settings › Storage › Erase All Data. Signs out (so the account and
    /// Trakt let go of this device's session), leaves a note for the next
    /// launch, and quits. The wipe itself happens at the next launch, before
    /// anything opens the library (`EraseAllData.runIfPending`): deleting the
    /// store while it's open could be written back over on the way out.
    func eraseAllDataAndQuit() async {
        let signOut = Task { @MainActor in
            await account.signOut(force: true)  // everything here is being erased anyway
            if trakt.isConnected { await trakt.disconnect() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await signOut.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }  // offline: don't wait on it
            await group.next()
            group.cancelAll()
        }
        EraseAllData.schedule()
        #if os(macOS)
        NSApp.quitFromTask()  // AppDelegate runs prepareForTermination
        #else
        await prepareForTermination()
        exit(0)
        #endif
    }
}

/// Everything Bluebox keeps on this device, deleted at launch after Erase All Data.
public enum EraseAllData {
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Inside the folder `AppModel.live` makes, so it's in Bluebox's own space
    /// even where there's no sandbox container.
    private static var marker: URL { appSupport.appending(path: "Bluebox/.erase-all-data") }

    static func schedule() {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    /// Call first thing at launch. Does nothing unless Erase All Data was chosen.
    public static func runIfPending() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: marker.path) else { return }
        Log.persistence.notice("Erasing all data, as asked in Settings")

        // Files. In a sandbox (iOS, the Mac app) these folders are Bluebox's
        // alone, so everything in them goes; otherwise only Bluebox's own.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if isSandboxed {
            for dir in [appSupport, caches, documents, fm.temporaryDirectory] {
                for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: item)
                }
            }
        } else {
            for item in [appSupport.appending(path: "Bluebox"), appSupport.appending(path: "Torrent"),
                         caches.appending(path: "Artwork"), caches.appending(path: "Bluebox"),
                         caches.appending(path: "Subtitles"), caches.appending(path: "SkipSegments.json"),
                         documents.appending(path: "diagnostics")] {
                try? fm.removeItem(at: item)
            }
        }
        URLCache.shared.removeAllCachedResponses()

        // Settings, profiles' view memory, recent searches.
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }

        // Sign-ins and keys.
        KeychainStore().deleteAll()

        // The widgets' snapshot (in the App Group, outside these folders) and Spotlight.
        AppModel.eraseSystemSurfaces()

        try? fm.removeItem(at: marker)
    }

    private static var isSandboxed: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }
}
