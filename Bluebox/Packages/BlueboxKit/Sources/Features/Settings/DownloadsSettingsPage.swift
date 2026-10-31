import DesignSystem
import Downloads
import SwiftUI

/// Settings › Downloads: what's saved on this device, how downloads behave,
/// and the `DownloadSettings` controls.
struct DownloadsSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var usedBytes: Int64?
    /// Counted when downloads change, not on every progress tick.
    @State private var finished = 0
    @State private var inProgress = 0

    var body: some View {
        SettingsForm(.downloads) {
            Section {
                LabeledContent("Downloaded", value: finished == 0 ? ByteText.zero : finished == 1 ? "1 video" : "\(finished) videos")
                LabeledContent("In Progress", value: inProgress == 0 ? ByteText.zero : "\(inProgress)")
                LabeledContent("Space Used", value: usedBytes.map(ByteText.string) ?? "Calculating…")
                    .settingsRow("Downloads Space Used")
                SettingsLink("Manage Downloads") {
                    DownloadsView()
                        .navigationTitle("Downloads")
                }
                .settingsRow("Manage Downloads")
            } header: {
                Text("On This Device")
            } footer: {
                Text("Pause, resume or delete them here or in the Downloads tab.")
            }

            Section {
                SettingsPicker("Simultaneous Downloads", selection: download(\.maxConcurrent),
                               options: DownloadSettings.concurrencyChoices.map { .init("\($0)", value: $0) })
                    .settingsRow("Simultaneous Downloads")
                #if os(iOS)
                // Wi‑Fi Only is set on Mobile Data, with the rest of what may use it.
                SettingsPageLink("Mobile Data", page: .mobileData,
                                 value: app.downloadSettings.wifiOnly ? "Wi‑Fi Only" : "Allowed")
                #endif
            } header: {
                Text("Downloading")
            } footer: {
                Text("More at once finishes a queue sooner but splits your bandwidth.")
            }

            let smart = app.downloadSettings.smartDownloads
            let deletes = app.downloadSettings.allowsDeleting
            Section {
                Toggle("Smart Downloads", isOn: download(\.smartDownloads))
                    .settingsRow("Smart Downloads")
                SettingsPicker("Keep Next Episodes", selection: download(\.keepNextEpisodes),
                               options: DownloadSettings.keepNextChoices.map { .init("\($0)", value: $0) })
                    .settingsRow("Keep Next Episodes")
                    .disabled(!smart)
                Toggle("Delete After Watching", isOn: download(\.deleteWatchedEpisodes))
                    .settingsRow("Delete After Watching")
                    .disabled(!smart || !deletes)
                SettingsPicker("Delete Watched Films", selection: download(\.deleteWatchedFilmsAfterDays),
                               options: DownloadSettings.filmDayChoices.map { .init(Self.filmDays($0), value: $0) })
                    .settingsRow("Delete Watched Films")
                    .disabled(!smart || !deletes)
                SettingsPicker("Storage Limit", selection: download(\.storageLimitBytes),
                               options: DownloadSettings.storageLimitChoices.map { .init(Self.limit($0), value: $0) })
                    .settingsRow("Storage Limit")
                    .disabled(!smart)
            } header: {
                Text("Smart Downloads")
            } footer: {
                Text(smart ? smartFooter : "Watched downloads stay until you delete them, and the next episodes aren't fetched.")
            }

            Section {
                Toggle("Smart Downloads Can Delete Watched Downloads", isOn: download(\.allowsDeleting))
                    .settingsRow("Smart Downloads Can Delete Watched Downloads")
                Toggle("Follow Watching on Other Devices", isOn: download(\.followOtherDevices))
                    .settingsRow("Follow Watching on Other Devices")
                    .disabled(!smart)
                SettingsPicker("Download Window", selection: download(\.window),
                               options: DownloadWindow.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Download Window")
                Toggle("Subtitles With Downloads", isOn: download(\.fetchSubtitles))
                    .settingsRow("Subtitles With Downloads")
            } header: {
                Text("What Bluebox Does on Its Own")
            } footer: {
                Text(automaticFooter)
            }

            Section {
                SettingsPicker("Download Quality", selection: download(\.downloadQuality),
                               options: DownloadQuality.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Download Quality")
                SettingsPicker("Largest Episode", selection: download(\.maxEpisodeBytes),
                               options: DownloadSettings.episodeSizeChoices.map { .init($0.map(SettingsSizes.label) ?? "Any Size", value: $0) })
                    .settingsRow("Largest Episode")
                SettingsPicker("Download Audio", selection: download(\.audioLanguage),
                               options: [.init("Profile's Language", value: nil)] + SettingsLanguages.options)
                    .settingsRow("Download Audio")
            } header: {
                Text("Quality")
            } footer: {
                Text("Used whenever Bluebox picks the release to download: Smart Downloads, new episodes and the Download buttons. Streaming keeps its own quality, and a release you choose yourself is downloaded as it is. Each show can choose its own in its Download Rules.")
            }

            #if os(iOS)
            Section {
                Toggle("Keep Downloading in the Background", isOn: download(\.keepDownloadingInBackground))
                    .settingsRow("Keep Downloading in the Background")
            } footer: {
                Text(app.downloadSettings.keepDownloadingInBackground
                     ? "Torrents keep downloading after you leave Bluebox, which uses more battery."
                     : "Torrents only download while Bluebox is open.")
            }

            Section {
                Toggle("Keep Screen Awake While Downloading", isOn: download(\.keepScreenAwake))
                    .settingsRow("Keep Screen Awake While Downloading")
            } footer: {
                Text("The screen stays on while the Downloads page is open and torrents are downloading.")
            }
            #endif

            #if os(macOS)
            MenuBarDownloadsSection()  // MenuBarDownloads.swift
            #endif

            Section {
                LabeledContent("Debrid Links", value: "In the Background")
                LabeledContent("Torrents", value: torrentsInBackground ? "In the Background" : "While Bluebox Is Open")
            } header: {
                Text("How Downloads Work")
            } footer: {
                Text(torrentsInBackground
                     ? "If iOS stops Bluebox in the background, torrents pause and you get a notification. They continue when you open Bluebox, and may continue while your device charges."
                     : "Torrents pick up again the next time you open Bluebox, unless you paused them.")
            }
        }
        .background {
            DownloadsChangeObserver {
                let manager = app.downloads
                let records = manager.all()
                let done = records.filter { $0.state == .completed }.count
                if done != finished { finished = done }
                if records.count - done != inProgress { inProgress = records.count - done }
                let used = await Task.detached { manager.usedBytes() }.value
                if used != usedBytes { usedBytes = used }
            }
        }
    }

    private var smartFooter: String {
        let s = app.downloadSettings
        let next = s.keepNextEpisodes == 1 ? "the next episode downloads" : "the next \(s.keepNextEpisodes) download"
        let deleting = s.allowsDeleting && s.deleteWatchedEpisodes
            ? "Watch an episode and it's deleted (with Undo) while \(next) on Wi‑Fi."
            : "Watch an episode and \(next) on Wi‑Fi; watched ones stay."
        let room = s.storageLimitBytes == nil ? "" : s.allowsDeleting
            ? " At the storage limit, the oldest watched downloads make room; unwatched ones are never deleted."
            : " Nothing new downloads past the storage limit."
        return deleting + room + " Each show can have its own rules in its Download Rules card."
    }

    private var automaticFooter: String {
        let s = app.downloadSettings
        var parts: [String] = []
        parts.append(s.allowsDeleting
                     ? "Smart Downloads may delete downloads you've watched, always with Undo when you're here."
                     : "Smart Downloads never deletes anything; it only adds downloads.")
        parts.append(s.followOtherDevices
                     ? "Watching on another device or Trakt counts too, so this device keeps up."
                     : "Only watching on this device counts.")
        switch s.window {
        case .anyTime: break
        case .overnight: parts.append("Downloads Bluebox starts by itself wait until 1–6 am.")
        case .whileCharging: parts.append("Downloads Bluebox starts by itself wait until the device is charging.")
        }
        if s.fetchSubtitles {
            parts.append(app.hasOpenSubtitlesKey
                         ? "Each download gets subtitles in the profile's subtitle language, for watching offline."
                         : "Subtitles need an OpenSubtitles key in Settings › Subtitles.")
        }
        return parts.joined(separator: " ")
    }

    static func filmDays(_ days: Int?) -> String {
        switch days {
        case nil: "Never"
        case 0: "Right Away"
        case 1: "After a Day"
        case let d?: "After \(d) Days"
        }
    }

    static func limit(_ bytes: Int64?) -> String {
        bytes.map { "\($0 / 1_000_000_000) GB" } ?? "No Limit"
    }

    /// iOS with Keep Downloading in the Background on.
    private var torrentsInBackground: Bool {
        #if os(iOS)
        app.downloadSettings.keepDownloadingInBackground
        #else
        false
        #endif
    }

    private func download<T>(_ keyPath: WritableKeyPath<DownloadSettings, T>) -> Binding<T> {
        Binding { app.downloadSettings[keyPath: keyPath] } set: { value in
            var s = app.downloadSettings
            s[keyPath: keyPath] = value
            app.setDownloadSettings(s)
        }
    }
}
