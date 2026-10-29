#if os(macOS)
import DesignSystem
import Downloads
import SwiftUI

/// Mac menu bar downloads (DECISIONS.md, UI review 17): a mini queue with
/// progress, Pause/Resume All and Open Downloads. The app inserts it while
/// anything is downloading or queued, or always with `alwaysShowKey` on.
public enum MenuBarDownloads {
    /// UserDefaults: keep the menu bar item when nothing is downloading.
    public static let alwaysShowKey = "bluebox.menuBarDownloads.alwaysShow"
    /// Rows shown before "and N more".
    static let rowLimit = 6
}

public struct MenuBarDownloadsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(MenuBarDownloads.alwaysShowKey) private var alwaysShow = false
    let openDownloads: () -> Void

    public init(openDownloads: @escaping () -> Void) { self.openDownloads = openDownloads }

    public var body: some View {
        let _ = app.downloadsRevision  // progress ticks
        let manager = app.downloads
        let queue = manager.queue()
        let rows = queue.prefix(MenuBarDownloads.rowLimit)
            .map { DownloadRowModel(record: $0, stats: manager.liveStats($0.id), wait: manager.wait($0.id)) }
        let canPause = queue.contains(where: \.isActive)
        let canResume = queue.contains { $0.state == .paused || $0.isFailed }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if app.activeDownloadCount > 0 {
                    Text("\(app.activeDownloadCount) active").font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, Spacing.l).padding(.top, Spacing.m).padding(.bottom, Spacing.s)

            if rows.isEmpty {
                Text("Nothing is downloading.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
            } else {
                VStack(spacing: Spacing.m) {
                    ForEach(rows) { MenuBarDownloadRow(row: $0) }
                    if queue.count > rows.count {
                        Text("and \(queue.count - rows.count) more")
                            .font(.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            }

            Divider().padding(.vertical, Spacing.s)

            HStack(spacing: Spacing.s) {
                if canPause || !canResume {
                    Button("Pause All", systemImage: "pause.fill") { app.pauseAllDownloads() }
                        .disabled(!canPause)
                } else {
                    Button("Resume All", systemImage: "play.fill") { app.resumeAllDownloads() }
                }
                Spacer()
                Button("Open Downloads", action: openDownloads)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.horizontal, Spacing.l)

            Divider().padding(.vertical, Spacing.s)

            Toggle("Always Show in Menu Bar", isOn: $alwaysShow)
                .toggleStyle(.checkbox)
                .padding(.horizontal, Spacing.l)
            Button("Quit Bluebox") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.l).padding(.top, Spacing.s).padding(.bottom, Spacing.m)
        }
        .frame(width: 320)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}

/// Settings › Downloads: the same switch as the menu's own checkbox.
struct MenuBarDownloadsSection: View {
    @AppStorage(MenuBarDownloads.alwaysShowKey) private var alwaysShow = false

    var body: some View {
        Section {
            Toggle("Always Show in Menu Bar", isOn: $alwaysShow)
                .settingsRow("Always Show in Menu Bar")
        } footer: {
            Text(alwaysShow ? "Downloads stay in the menu bar even when nothing is downloading."
                            : "Downloads appear in the menu bar while something is downloading.")
        }
    }
}

/// Title, episode, a progress bar (blue while it transfers, grey otherwise) and the row's status line.
private struct MenuBarDownloadRow: View {
    let row: DownloadRowModel

    var body: some View {
        let record = row.record
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Spacing.xs) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let episode = row.episodeLabel {
                    Text(episode).font(.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            ProgressView(value: record.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(record.state == .downloading ? Palette.brand : Palette.textTertiary)
            Text(statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The Downloads tab's status ("62% · 2m left"), plus the speed while it transfers.
    private var statusLine: String {
        guard row.record.state == .downloading, let speed = row.stats?.bytesPerSecond, speed >= 1_000 else { return row.status }
        return "\(row.status) · \(Formatters.bytes(Int64(speed)))/s"
    }
}
#endif
