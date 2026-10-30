import DesignSystem
import Domain
import Downloads
import SwiftUI

/// One line for a show's download rules: "Keeping next 2 · 1080p · Wi‑Fi ·
/// delete after watching". Pure, so it's tested directly.
enum DownloadRuleSummary {
    static func text(_ rule: DownloadRule, window: DownloadWindow, newEpisodes: Bool) -> String {
        guard rule.smartDownloads else {
            return newEpisodes ? "Smart Downloads off · new episodes download" : "Smart Downloads off · keeps what you download"
        }
        var parts = ["Keeping next \(rule.keepNext)"]
        if rule.quality != .best { parts.append(rule.quality.title) }
        if let max = rule.maxEpisodeBytes { parts.append("up to \(SettingsSizes.label(max)) an episode") }
        switch window {
        case .anyTime: parts.append("Wi‑Fi")
        case .overnight: parts.append("Wi‑Fi overnight")
        case .whileCharging: parts.append("Wi‑Fi while charging")
        }
        if let lang = rule.audioLanguage { parts.append(SettingsLanguages.name(lang) + " audio") }
        parts.append(rule.deleteAfterWatching ? "delete after watching" : "keep after watching")
        if newEpisodes { parts.append("new episodes") }
        return parts.joined(separator: " · ")
    }
}

/// Byte sizes in Settings' pickers: "3 GB".
enum SettingsSizes {
    static func label(_ bytes: Int64) -> String { "\(bytes / 1_000_000_000) GB" }
}

/// A show's "Download Rules" card: the rule it follows ("Using defaults" or
/// its own), in one line, with Edit. On the title page beside the season
/// bar, and on the show's Downloads page. A plain symbol, never a sparkle.
struct ShowDownloadRulesCard: View {
    @Environment(AppModel.self) private var app
    let series: MediaKey
    let showName: String
    @State private var editing = false

    var body: some View {
        let settings = app.downloadSettings
        let rule = settings.rule(for: series)
        let custom = rule.isCustom || app.newEpisodeSettings.autoDownloadShows[series.rawValue] != nil
        let summary = DownloadRuleSummary.text(rule, window: settings.window, newEpisodes: app.autoDownloadsNewEpisodes(series))
        Button { editing = true } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(rule.smartDownloads ? Palette.textPrimary : Palette.textTertiary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Download Rules").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        Text(custom ? "Custom" : "Using defaults").font(.caption).foregroundStyle(Palette.textTertiary)
                    }
                    Text(summary).font(.caption).foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.s)
                Text("Edit").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brandBright)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s + 2)
            .frame(minHeight: 52)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download rules, \(custom ? "custom" : "using defaults"), \(summary)")
        .accessibilityHint("Edits this show's download rules")
        .accessibilityIdentifier("showDownloadRules")
        .sheet(isPresented: $editing) {
            ShowDownloadRulesSheet(series: series, showName: showName).environment(app)
        }
    }
}

/// Editing one show's rules: Smart Downloads (with keep next, quality, audio
/// language and delete after watching under it) and download new episodes.
/// They start as Settings' rules; changing any of them gives the show its
/// own, and Reset to Settings goes back.
struct ShowDownloadRulesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let series: MediaKey
    let showName: String

    private var settings: DownloadSettings { app.downloadSettings }
    private var raw: String { series.rawValue }
    private var isCustom: Bool {
        settings.showRules[raw] != nil || app.newEpisodeSettings.autoDownloadShows[raw] != nil
    }

    var body: some View {
        let current = settings.rule(for: series)
        NavigationStack {
            SettingsForm(title: "Download Rules") {
                Section {
                    Toggle("Smart Downloads", isOn: rule(\.smartDownloads, current.smartDownloads))
                    if current.smartDownloads {
                        SettingsChoiceLink("Keep Next", selection: rule(\.keepNext, current.keepNext),
                                           options: DownloadSettings.keepNextChoices.map { .init($0 == 1 ? "1 episode" : "\($0) episodes", value: $0) },
                                           footer: "How many unwatched episodes stay downloaded ahead of where you are.")
                        SettingsChoiceLink("Quality", selection: rule(\.quality, current.quality),
                                           options: DownloadQuality.allCases.map { .init($0.title, value: $0) })
                        SettingsChoiceLink("Audio", selection: audio,
                                           options: [.init("Profile's Language", value: nil)] + SettingsLanguages.options)
                        Toggle("Delete After Watching", isOn: rule(\.deleteAfterWatching, current.deleteAfterWatching))
                            .disabled(!settings.allowsDeleting)
                    }
                } header: {
                    Text(isCustom ? "\(showName) · its own rules" : "\(showName) · same as Settings")
                } footer: {
                    Text(!current.smartDownloads
                         ? "Smart Downloads keeps the next episodes downloaded on Wi‑Fi."
                         : settings.allowsDeleting
                         ? "Keeps the next episodes downloaded on Wi‑Fi and, if you like, deletes the ones you've watched."
                         : "Nothing is deleted: Settings › Downloads › Smart Downloads Can Delete Watched Downloads is off.")
                }

                Section {
                    Toggle("Download New Episodes", isOn: Binding(get: { app.autoDownloadsNewEpisodes(series) }, set: {
                        app.setAutoDownloadNewEpisodes($0, for: series)
                    }))
                } footer: {
                    Text(isCustom ? "New episodes download on Wi‑Fi as they come out."
                                  : "New episodes download on Wi‑Fi as they come out. Everything here follows Settings › Downloads until you change it.")
                }

                if isCustom {
                    Section {
                        Button("Reset to Settings") { resetToSettings() }
                            .buttonStyle(SettingsActionStyle())
                    } footer: {
                        Text("\(showName) has its own rules. Reset to follow Settings › Downloads again.")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #else
        .presentationDetents([.large])
        .presentationBackground(Palette.background)
        #endif
        .preferredColorScheme(.dark)
    }

    /// One override: shows the rule in force; setting it makes the show Custom.
    private func rule<T>(_ keyPath: WritableKeyPath<ShowDownloadRule, T?>, _ current: T) -> Binding<T> {
        Binding {
            settings.showRules[raw]?[keyPath: keyPath] ?? current
        } set: { value in
            var own = settings.showRules[raw] ?? snapshot()
            own[keyPath: keyPath] = value
            app.setShowDownloadRule(own, for: series)
        }
    }

    private var audio: Binding<String?> {
        Binding {
            settings.rule(for: series).audioLanguage
        } set: { value in
            var own = settings.showRules[raw] ?? snapshot()
            own.audioLanguage = value
            app.setShowDownloadRule(own, for: series)
        }
    }

    /// The rule in force now, as the show's own: Custom starts from it.
    private func snapshot() -> ShowDownloadRule {
        let r = settings.rule(for: series)
        return ShowDownloadRule(smartDownloads: r.smartDownloads, keepNext: r.keepNext, quality: r.quality,
                                audioLanguage: settings.audioLanguage == r.audioLanguage ? nil : r.audioLanguage,
                                deleteAfterWatching: settings.allowsDeleting ? r.deleteAfterWatching : settings.deleteWatchedEpisodes)
    }

    private func resetToSettings() {
        app.setShowDownloadRule(nil, for: series)
        app.setAutoDownloadNewEpisodes(nil, for: series)
    }
}
