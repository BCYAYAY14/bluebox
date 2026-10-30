import Addons
import DesignSystem
import Downloads
import Foundation
import Subtitles
import SwiftUI
import TorrentStreaming

/// Settings › Storage: what Bluebox keeps on disk, with a Clear button for
/// each cache, Clear Search History, Reset All Settings and Erase All Data.
struct StorageSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var usage = StorageUsage()
    @State private var loaded = false
    @State private var confirm: Confirmation?
    @State private var erasing = false

    enum Confirmation: String, Identifiable {
        case artwork, catalog, subtitles, streams, all, searchHistory, reset, erase
        var id: String { rawValue }
    }

    var body: some View {
        SettingsForm(.storage) {
            Section {
                cacheRow("Artwork", bytes: usage.artwork, symbol: "photo.on.rectangle", clear: .artwork)
                cacheRow("Catalog Data", bytes: usage.catalog, symbol: "film.stack", clear: .catalog)
                cacheRow("Downloaded Subtitles", bytes: usage.subtitles, symbol: "captions.bubble", clear: .subtitles)
                cacheRow("Stream Cache", bytes: usage.streams, symbol: "point.3.connected.trianglepath.dotted", clear: .streams,
                         disabled: app.activePlayer != nil)
                Button("Clear All Caches", role: .destructive) { confirm = .all }
                    .disabled(!loaded || usage.cachesTotal == 0)
                    .settingsRow("Clear All Caches")
            } header: {
                Text("Caches")
            } footer: {
                Text("Caches rebuild as you browse. Clearing them doesn't touch My List, progress or downloads.")
            }

            Section {
                SettingsLink("Downloads", value: loaded ? ByteText.string(usage.downloads) : "…") {
                    DownloadsView()
                        .navigationTitle("Downloads")
                }
                LabeledContent("Diagnostics", value: loaded ? ByteText.string(usage.diagnostics) : "…")
            } header: {
                Text("Your Files")
            } footer: {
                Text("Open Downloads to delete them. Diagnostics are cleared in Advanced.")
            }

            Section {
                Button("Clear Search History", role: .destructive) { confirm = .searchHistory }
                    .settingsRow("Clear Search History")
            } header: {
                Text("History")
            } footer: {
                Text("Recent searches for every profile on this device.")
            }

            Section {
                Button("Reset All Settings", role: .destructive) { confirm = .reset }
                    .settingsRow("Reset All Settings")
                Button("Erase All Data", role: .destructive) { confirm = .erase }
                    .disabled(erasing)
                    .settingsRow("Erase All Data")
            } header: {
                Text("Reset")
            } footer: {
                Text("Reset All Settings puts settings back to their defaults and keeps everything else. Erase All Data deletes everything Bluebox keeps on this device, then \(Self.quitWord). What's in your account stays there.")
            }
        }
        .task { await refresh() }
        .confirmationDialog(title(for: confirm), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button(confirmTitle(for: c), role: .destructive) { Task { await perform(c) } }
        } message: { c in
            Text(message(for: c))
        }
    }

    private func cacheRow(_ title: String, bytes: Int64, symbol: String, clear: Confirmation, disabled: Bool = false) -> some View {
        HStack(spacing: Spacing.l) {
            Text(title)
            Spacer()
            Text(loaded ? ByteText.string(bytes) : "…").foregroundStyle(Palette.textSecondary).monospacedDigit()
            Button("Clear") { confirm = clear }
                .buttonStyle(TextActionStyle())
                .disabled(!loaded || bytes == 0 || disabled)
                .accessibilityLabel("Clear \(title)")
        }
        .settingsRow("Clear \(title)")
    }

    private func title(for c: Confirmation?) -> String {
        switch c {
        case .artwork: "Clear artwork?"
        case .catalog: "Clear catalog data?"
        case .subtitles: "Clear downloaded subtitles?"
        case .streams: "Clear the stream cache?"
        case .all: "Clear all caches?"
        case .searchHistory: "Clear search history?"
        case .reset: "Reset all settings?"
        case .erase: "Erase all data on this device?"
        case nil: ""
        }
    }

    private func message(for c: Confirmation) -> String {
        switch c {
        case .artwork: "Posters and backdrops download again as you browse."
        case .catalog: "Titles, seasons and search results load again from TMDB."
        case .subtitles: "Subtitles you found online are deleted. Search again from the player to get them back."
        case .streams: "Kept streams are deleted. Watching them again downloads them again."
        case .all: "Artwork, catalog data, downloaded subtitles and kept streams are deleted. Downloads stay."
        case .searchHistory: "Recent searches are removed for every profile on this device."
        case .reset: "This can't be undone. Your library, profiles, sources, downloads and keys stay."
        case .erase: "This can't be undone. Your library, profiles, watch progress, search history, settings, sources, downloads, caches, sign-ins and keys are deleted from this device, and Bluebox \(Self.quitWord). Anything synced to your account or Trakt stays there, and comes back when you sign in again."
        }
    }

    private func confirmTitle(for c: Confirmation) -> String {
        switch c {
        case .searchHistory: "Clear Search History"
        case .reset: "Reset All Settings"
        case .erase: "Erase All Data"
        default: "Clear"
        }
    }

    #if os(macOS)
    static let quitWord = "quits"
    #else
    static let quitWord = "closes"
    #endif

    private func perform(_ c: Confirmation) async {
        switch c {
        case .artwork: await ImagePipeline.shared.clearDisk()
        case .catalog: URLCache.shared.removeAllCachedResponses()
        case .subtitles: await Task.detached { try? FileManager.default.removeItem(at: StorageUsage.subtitlesDirectory) }.value
        case .streams: if app.activePlayer == nil { await Task.detached { StreamCache.clear() }.value }
        case .all:
            await ImagePipeline.shared.clearDisk()
            URLCache.shared.removeAllCachedResponses()
            await Task.detached { try? FileManager.default.removeItem(at: StorageUsage.subtitlesDirectory) }.value
            if app.activePlayer == nil { await Task.detached { StreamCache.clear() }.value }
        case .searchHistory:
            app.clearSearchHistory()
        case .reset:
            app.resetAllSettings()
        case .erase:
            erasing = true
            await app.eraseAllDataAndQuit()
            return
        }
        await refresh()
    }

    private func refresh() async {
        usage = await StorageUsage.measure(downloads: app.downloads)
        loaded = true
    }
}

/// Bytes used by each thing Bluebox stores.
struct StorageUsage: Sendable {
    var artwork: Int64 = 0
    var catalog: Int64 = 0
    var subtitles: Int64 = 0
    var streams: Int64 = 0
    var downloads: Int64 = 0
    var diagnostics: Int64 = 0

    var cachesTotal: Int64 { artwork + catalog + subtitles + streams }

    /// Where `AppModel.downloadSubtitle` saves subtitles found online.
    static var subtitlesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Subtitles", directoryHint: .isDirectory)
    }

    /// Where `TorrentDiagnostics` writes its metrics (Documents/diagnostics).
    static var diagnosticsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "diagnostics", directoryHint: .isDirectory)
    }

    static func measure(downloads: DownloadManager) async -> StorageUsage {
        var u = StorageUsage()
        u.artwork = Int64(await ImagePipeline.shared.diskUsage)
        u.catalog = Int64(URLCache.shared.currentDiskUsage)
        let files = await Task.detached {
            (directorySize(subtitlesDirectory), StreamCache.totalBytes(), downloads.usedBytes(), directorySize(diagnosticsDirectory))
        }.value
        (u.subtitles, u.streams, u.downloads, u.diagnostics) = files
        return u
    }

    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

extension AppModel {
    /// Settings › Storage › Reset All Settings. Library, profiles, sources,
    /// downloads and Keychain secrets aren't settings and stay.
    func resetAllSettings() {
        subtitleStyle = SubtitleStyle()
        defaultSpeed = 1
        // Add-ons added by link are sources, not settings: they stay.
        var addonDefaults = AddonSettings()
        addonDefaults.addons += addonSettings.addons.filter { $0.preset == nil }
        addonDefaults.customLinks = addonSettings.customLinks
        setAddonSettings(addonDefaults)
        settings.resetToDefaults()
    }
}
