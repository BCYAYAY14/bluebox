import DesignSystem
import Downloads
import SwiftUI

/// Settings › Mobile Data (iPhone and iPad): streaming, quality and torrents on
/// mobile data, Wi‑Fi Only downloads, and how much was used this month. Low
/// Data Mode and hotspots count as mobile data.
struct MobileDataSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm(.mobileData) {
            Section {
                LabeledContent("Connection", value: connection)
            } footer: {
                Text("Low Data Mode and personal hotspots count as mobile data.")
            }

            Section {
                SettingsPicker("Streaming", selection: $settings.mobileData.streaming,
                               options: MobileDataSettings.Streaming.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Streaming on Mobile Data")
                SettingsPicker("Video Quality", selection: $settings.mobileData.quality, options: [
                    .init("Data Saver (up to 720p)", value: .dataSaver),
                    .init("Automatic (up to 1080p)", value: .automatic),
                    .init("Best Available", value: .best),
                ])
                .settingsRow("Video Quality on Mobile Data")
            } header: {
                Text("Streaming")
            } footer: {
                Text(streamingFooter)
            }

            Section {
                SettingsPicker("Torrents", selection: $settings.mobileData.torrents,
                               options: MobileDataSettings.Torrents.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Torrents on Mobile Data")
                // "Upload While Streaming" (`mobileData.allowUpload`) returns once the
                // torrent engine can limit uploads; until then it would do nothing.
            } header: {
                Text("Torrents")
            } footer: {
                Text(torrentsFooter)
            }

            Section {
                Toggle("Wi‑Fi Only", isOn: wifiOnly)
                    .settingsRow("Downloads on Wi‑Fi Only")
            } header: {
                Text("Downloads")
            } footer: {
                Text(app.downloadSettings.wifiOnly
                     ? "Downloads wait for Wi‑Fi. Choose Download Now on a download to use mobile data for it."
                     : "Downloads use mobile data too.")
            }

            Section {
                LabeledContent("Used This Month", value: ByteText.amount(settings.dataUsage.totalBytes))
                    .settingsRow("Data Used This Month")
                LabeledContent("Streaming", value: ByteText.amount(settings.dataUsage.streamingBytes))
                LabeledContent("Downloads", value: ByteText.amount(settings.dataUsage.downloadBytes))
                Button("Reset Counter", role: .destructive) { confirmReset = true }
                    .disabled(settings.dataUsage.totalBytes == 0)
                    .confirmationDialog("Reset the counter?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset Counter", role: .destructive) { app.resetMobileDataUsage() }
                    } message: {
                        Text("Data used on mobile data starts again from zero.")
                    }
            } header: {
                Text("Data Used")
            } footer: {
                Text("Since \(settings.dataUsage.since.formatted(date: .abbreviated, time: .omitted)). Debrid streams are estimated from the file size. Your carrier's count is the one that matters.")
            }
        }
    }

    private var connection: String {
        let n = app.settings.network
        if !n.isOnline { return "Offline" }
        if n.isConstrained { return "Low Data Mode" }
        if n.isMobileData { return n.usesCellular ? "Mobile Data" : "Hotspot" }
        return n.usesWiFi ? "Wi‑Fi" : "Connected"
    }

    private var streamingFooter: String {
        let rules = app.settings.mobileData
        let streaming = switch rules.streaming {
        case .allow: "Videos stream on mobile data without asking."
        case .askFirst: "Play asks first, with the size of the video."
        case .never: "Videos stream on Wi‑Fi only. Downloads play anywhere."
        }
        let quality = switch rules.quality {
        case .dataSaver: "Data Saver picks the smallest good release up to 720p."
        case .automatic: "Automatic plays up to 1080p."
        case .best: "Best Available ignores the data cost."
        }
        return "\(streaming) \(quality)"
    }

    private var torrentsFooter: String {
        switch app.settings.mobileData.torrents {
        case .allow:
            "Peer-to-peer streams use more data than debrid links, and share with other peers while they play. Choose Debrid Only to avoid uploading."
        case .debridOnly:
            "Only debrid links play on mobile data; peer-to-peer uses more data and uploads."
        case .never:
            "No torrents or debrid links on mobile data. Your own files and servers still play."
        }
    }

    private var wifiOnly: Binding<Bool> {
        Binding { app.downloadSettings.wifiOnly } set: { on in
            var s = app.downloadSettings
            s.wifiOnly = on
            app.setDownloadSettings(s)
        }
    }
}

extension ByteText {
    /// "0 KB" (not "None", and not the formatter's "Zero KB"), for counters.
    static func amount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]  // never "0 bytes"
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}
