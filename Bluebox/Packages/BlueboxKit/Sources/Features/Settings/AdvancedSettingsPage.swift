import DesignSystem
import Domain
import Foundation
import OSLog
import SwiftUI

/// Settings › Advanced: torrent diagnostics, the app log (view and export),
/// and the launch intro.
struct AdvancedSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm(.advanced) {
            Section {
                SettingsLink("Torrent Diagnostics") { TorrentDiagnosticsPage() }
                    .settingsRow("Torrent Diagnostics")
                SettingsLink("App Log") { LogViewerPage() }
                    .settingsRow("App Log")
                ExportLogsButton()
                    .settingsRow("Export Logs")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Peers, speed and network while a torrent streams. The exported log adds this session's app log. Tokens and keys are never logged.")
            }

            Section {
                Toggle("Play Intro at Launch", isOn: $settings.playLaunchIntro)
                    .settingsRow("Play Intro at Launch")
            } header: {
                Text("Launch")
            } footer: {
                Text("The wordmark animation when Bluebox opens.")
            }
        }
    }
}

// MARK: - Torrent diagnostics

/// Reads the metrics `TorrentDiagnostics` writes (one JSON object per line,
/// every 2 s while a torrent streams) and shows the latest one.
struct TorrentDiagnosticsPage: View {
    @State private var lines: [DiagnosticsLine] = []
    @State private var confirmClear = false

    var body: some View {
        let latest = lines.last { $0.event == nil }
        let live = latest.map { Date().timeIntervalSince($0.fileDate) < 8 } ?? false
        SettingsForm(title: "Torrent Diagnostics") {
            Section {
                if let s = latest {
                    LabeledContent("Status", value: live ? "Streaming" : "Last stream")
                    LabeledContent("Torrent", value: s.string("state") ?? "–")
                    LabeledContent("Download Speed", value: Self.rate(s.int("rate")))
                    LabeledContent("Peers", value: "\(s.int("peers") ?? 0) (\(s.int("seeds") ?? 0) seeds)")
                    LabeledContent("Connections", value: "\(s.int("conns") ?? 0) of \(s.int("candidates") ?? 0) candidates")
                    LabeledContent("Downloaded", value: "\(s.int("doneMB") ?? 0) of \(s.int("wantedMB") ?? 0) MB")
                    LabeledContent("Playhead", value: (s.int("playheadMB") ?? -1) < 0 ? "–" : "\(s.int("playheadMB")!) MB")
                    LabeledContent("DHT Nodes", value: "\(s.int("dhtNodes") ?? 0)")
                    LabeledContent("Network", value: network(s))
                    if let reasons = s.object("reasons"), !reasons.isEmpty {
                        LabeledContent("Disconnects", value: reasons.sorted { ($0.value as? Int ?? 0) > ($1.value as? Int ?? 0) }
                            .prefix(3).map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
                    }
                } else {
                    Text("Nothing yet. Stream a torrent and its numbers show up here.")
                        .foregroundStyle(Palette.textSecondary)
                }
            } header: {
                Text(live ? "Now" : "Latest")
            } footer: {
                if let s = latest, let time = s.string("time") { Text("Updated \(time).") }
            }

            if !lines.isEmpty {
                Section {
                    SettingsLink("Raw Metrics") { RawLogPage(title: "Raw Metrics", text: lines.suffix(300).map(\.raw).joined(separator: "\n")) }
                    if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                        ShareLink(item: Self.fileURL) { Label("Share Metrics File", systemImage: "square.and.arrow.up") }
                    }
                    Button("Clear Diagnostics", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("The metrics file keeps up to about 10 MB, then starts over.")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                lines = await Task.detached { Self.read() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Clear diagnostics?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Diagnostics", role: .destructive) {
                try? FileManager.default.removeItem(at: StorageUsage.diagnosticsDirectory)
                lines = []
            }
        } message: {
            Text("Saved torrent metrics are deleted. A stream that's playing starts a new file next time.")
        }
    }

    nonisolated static var fileURL: URL { StorageUsage.diagnosticsDirectory.appending(path: "metrics.jsonl") }

    /// The last ~400 lines of the metrics file.
    nonisolated static func read() -> [DiagnosticsLine] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 160_000
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? .distantPast
        var rows = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if size > window, !rows.isEmpty { rows.removeFirst() }  // probably cut mid-line
        return rows.suffix(400).compactMap { DiagnosticsLine(raw: String($0), fileDate: modified) }
    }

    nonisolated static func rate(_ bytesPerSecond: Int?) -> String {
        guard let b = bytesPerSecond, b > 0 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + "/s"
    }

    private func network(_ s: DiagnosticsLine) -> String {
        var parts = [s.string("net") ?? "?"]
        if s.bool("expensive") == true { parts.append("expensive") }
        if s.bool("constrained") == true { parts.append("Low Data Mode") }
        if s.bool("lowPower") == true { parts.append("Low Power") }
        return parts.joined(separator: ", ")
    }
}

struct DiagnosticsLine: Sendable {
    let raw: String
    let fileDate: Date
    private let json: [String: AnyHashableSendable]

    init?(raw: String, fileDate: Date) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        self.raw = raw
        self.fileDate = fileDate
        json = obj.mapValues(AnyHashableSendable.init)
    }

    var event: String? { string("event") }
    func string(_ k: String) -> String? { json[k]?.value as? String }
    func int(_ k: String) -> Int? { (json[k]?.value as? NSNumber)?.intValue }
    func bool(_ k: String) -> Bool? { (json[k]?.value as? NSNumber)?.boolValue }
    func object(_ k: String) -> [String: Any]? { json[k]?.value as? [String: Any] }
}

/// JSON values are immutable Foundation objects; this lets them cross actors.
struct AnyHashableSendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

// MARK: - App log

/// Bluebox's own log from this session (OSLog), newest last.
struct LogViewerPage: View {
    @State private var entries: [AppLog.Entry]?
    @State private var filter = ""

    var body: some View {
        let shown = (entries ?? []).filter { filter.isEmpty || $0.category == filter }
        let categories = Array(Set((entries ?? []).map(\.category))).sorted()
        List {
            if entries == nil {
                HStack { ProgressView().controlSize(.small); Text("Reading the log…") }
            } else if shown.isEmpty {
                Text("No log entries yet in this session.").foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(shown.suffix(500)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.s) {
                            Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                            Text(e.category).foregroundStyle(Palette.brand)
                            if e.isError { Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Error") }
                        }
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                        Text(e.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .blueboxScreen()
        .navigationTitle("App Log")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                BlueboxMenu("Filter") {
                    BlueboxMenuSection("Category") {
                        BlueboxMenuButton("All", checked: filter.isEmpty) { filter = "" }
                        for c in categories {
                            BlueboxMenuButton(c.capitalized, checked: filter == c) { filter = c }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .task { entries = await Task.detached { AppLog.read() }.value }
    }
}

/// Exports this session's log and the torrent metrics as one text file.
struct ExportLogsButton: View {
    @State private var file: URL?
    @State private var working = false

    var body: some View {
        if let file {
            ShareLink(item: file) { Label("Share Log File", systemImage: "square.and.arrow.up") }
        } else {
            Button {
                working = true
                Task {
                    file = await Task.detached { AppLog.exportFile() }.value
                    working = false
                }
            } label: {
                HStack {
                    Label(working ? "Preparing Log…" : "Export Logs…", systemImage: "doc.text")
                    if working { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(working)
        }
    }
}

enum AppLog {
    struct Entry: Identifiable, Sendable {
        let id: Int
        let date: Date
        let category: String
        let message: String
        let isError: Bool
    }

    /// Subsystems Bluebox logs under: `Log` (Domain) and libtorrent's.
    static let subsystems: Set<String> = [Log.subsystem, "TorrentKit"]

    nonisolated static func read(since: Date = .now.addingTimeInterval(-24 * 3600)) -> [Entry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let all = try? store.getEntries(at: store.position(date: since)) else { return [] }
        var out: [Entry] = []
        for case let e as OSLogEntryLog in all where subsystems.contains(e.subsystem) {
            out.append(Entry(id: out.count, date: e.date, category: e.subsystem == "TorrentKit" ? "torrent" : e.category,
                             message: e.composedMessage, isError: e.level == .error || e.level == .fault))
        }
        return out
    }

    nonisolated static func exportFile() -> URL? {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var text = "Bluebox \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nExported \(Date().formatted(.iso8601))\n\n"
        text += "== App log (this session) ==\n"
        for e in read() {
            text += "\(e.date.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(e.category)]\(e.isError ? " ERROR" : "") \(e.message)\n"
        }
        let metrics = TorrentDiagnosticsPage.read()
        if !metrics.isEmpty {
            text += "\n== Torrent metrics (latest \(metrics.count)) ==\n"
            text += metrics.map(\.raw).joined(separator: "\n") + "\n"
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory.appending(path: "Bluebox-Log-\(stamp).txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

struct RawLogPage: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Empty" : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .blueboxScreen()
        .navigationTitle(title)
    }
}
