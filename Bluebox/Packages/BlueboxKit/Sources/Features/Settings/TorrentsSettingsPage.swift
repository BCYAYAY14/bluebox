import Addons
import DesignSystem
import SwiftUI
import TorrentStreaming

/// Settings › Torrents & Debrid: which Stremio add-ons find releases and in
/// what order, the debrid service and release preferences. The libtorrent
/// engine (peers, buffering, upload, stream cache, port) is one level down,
/// in Torrent Engine. Everything here is `AddonSettings` (stored under
/// `bluebox.addons`) plus the debrid key in the Keychain.
struct TorrentsSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.settingsReveal) private var reveal
    @State private var debridKey = ""
    @State private var loadedKey = false
    @State private var health: SourceHealthText?
    @State private var testing = false
    @State private var showsEngine = false

    struct SourceHealthText: Equatable { let ok: Bool; let message: String }

    /// Binds straight to the app's settings, so a reset elsewhere shows here.
    private func setting<T>(_ keyPath: WritableKeyPath<AddonSettings, T>) -> Binding<T> {
        app.addonSetting(keyPath)
    }

    var body: some View {
        let settings = app.addonSettings
        SettingsForm(.torrents) {
            Section {
                Toggle("Find Releases with Add-ons", isOn: setting(\.isEnabled))
                    .settingsRow("Find Releases with Add-ons")
            } footer: {
                Text(app.addonsCanStreamTorrents
                     ? "Play asks your add-ons for releases and streams the best one."
                     : "Torrents can't stream here yet, so only debrid links play. Set up a debrid service below.")
            }

            if settings.isEnabled {
                addonsSection
                debridSection
                releasesSection
                engineSection
            }
        }
        .task {
            guard !loadedKey else { return }
            debridKey = app.debridKey
            loadedKey = true
        }
        .onChange(of: debridKey) { _, new in if loadedKey { app.setDebridKey(new) } }
        // A search hit for an engine setting opens Torrent Engine, which scrolls to it.
        .task(id: reveal?.target?.id) {
            if let target = reveal?.target, target.page == .torrents, target.subpage == TorrentEngineSettingsPage.title,
               app.addonSettings.isEnabled {
                showsEngine = true
            }
        }
        .navigationDestination(isPresented: $showsEngine) { TorrentEngineSettingsPage() }
    }

    // MARK: Sections

    private var addonsSection: some View {
        let addons = app.addonSettings.addons
        let on = addons.filter(\.isEnabled)
        return Section {
            SettingsLink("Add-ons", value: on.isEmpty ? "None On" : on.count <= 2 ? on.map(\.name).joined(separator: ", ") : "\(on.count) On") {
                AddonsSettingsPage()
            }
            .settingsRow("Add-ons")
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text(testing ? "Testing…" : "Test Add-ons")
                    if testing { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(testing || on.isEmpty)
            .settingsRow("Test Add-ons")
            if let health { SettingsStatus(ok: health.ok, message: health.message) }
        } header: {
            Text("Add-ons")
        } footer: {
            Text("Torrentio, StremThru and Comet are one tap away; any other Stremio add-on can be added by its link.")
        }
    }

    @ViewBuilder private var debridSection: some View {
        let settings = app.addonSettings
        Section {
            SettingsPicker("Service", selection: setting(\.debrid),
                           options: DebridProvider.allCases.map { .init($0.title, value: $0) })
                .settingsRow("Debrid Service")
            if settings.debrid.requiresKey {
                SecureField("API Key", text: $debridKey, prompt: Text("Paste your \(settings.debrid.title) key"))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                Toggle("Share Key with Community Add-ons", isOn: setting(\.shareKeyWithCommunityHosts))
                    .settingsRow("Share Key with Community Add-ons")
                if settings.debrid.canCheckCache {
                    Toggle("Check What's Cached", isOn: setting(\.checkDebridCache))
                        .settingsRow("Check What's Cached")
                }
            }
        } header: {
            Text("Debrid")
        } footer: {
            if let hint = settings.debrid.keyHint {
                Text("Find your key at \(hint). It stays in your Keychain and goes to Torrentio, and to StremThru and Comet only if you share it.")
            } else {
                Text("A debrid service fetches torrents for you and streams them over HTTPS, so playback starts at once.")
            }
        }
    }

    @ViewBuilder private var releasesSection: some View {
        Section {
            SettingsPicker("Sort By", selection: setting(\.sort),
                           options: ReleaseSort.allCases.map { .init($0.title, value: $0) })
                .settingsRow("Sort By")
            SettingsPicker("Preferred Resolution", selection: setting(\.preferredResolution), options: [
                .init("Best Available", value: nil), .init("4K", value: "2160p"),
                .init("1080p", value: "1080p"), .init("720p", value: "720p"),
            ])
            .settingsRow("Preferred Resolution")
            SettingsLink("Hidden Qualities", value: hiddenSummary) {
                HiddenQualitiesPage(hidden: setting(\.hiddenQualities))
            }
            .settingsRow("Hidden Qualities")
            Toggle("Same Group Next Episode", isOn: setting(\.rememberShowChoices))
                .settingsRow("Same Group Next Episode")
            Toggle("Find Releases Early", isOn: setting(\.prefetchReleases))
                .settingsRow("Find Releases Early")
        } header: {
            Text("Releases")
        } footer: {
            Text("Play picks cached debrid links first, then the healthiest release at your resolution that this device can play. Find Releases Early searches as soon as a movie's page opens.")
        }
    }

    /// The engine's settings live one level down, so this page stays about finding releases.
    private var engineSection: some View {
        Section {
            Button { showsEngine = true } label: {
                HStack(spacing: Spacing.l) {
                    Text(TorrentEngineSettingsPage.title).foregroundStyle(Palette.textPrimary).layoutPriority(1)
                    Spacer(minLength: 0)
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowPressStyle())
            .settingsRow("Torrent Engine")
        } header: {
            Text("Advanced")
        } footer: {
            Text("Peers, buffering, uploads, the stream cache and the stream server.")
        }
    }

    // MARK: Helpers

    /// Short names, so the row never truncates: "CAM, Screeners", or a count past two.
    private var hiddenSummary: String {
        let hidden = QualityFilter.offered.filter(app.addonSettings.hiddenQualities.contains)
        switch hidden.count {
        case 0: return "None"
        case 1, 2: return hidden.map(\.shortTitle).joined(separator: ", ")
        default: return "\(hidden.count) Hidden"
        }
    }

    private func test() async {
        health = nil
        testing = true
        defer { testing = false }
        let result = await app.testAddons()
        health = SourceHealthText(ok: result.ok, message: result.message)
    }
}

private extension QualityFilter {
    /// For summaries in a row's value.
    var shortTitle: String {
        switch self {
        case .cam: "CAM"
        case .unknown: "Unknown"
        default: title
        }
    }
}

extension AppModel {
    /// A binding straight to one add-on setting, so a reset elsewhere shows at once.
    func addonSetting<T>(_ keyPath: WritableKeyPath<AddonSettings, T>) -> Binding<T> {
        Binding {
            self.addonSettings[keyPath: keyPath]
        } set: { value in
            var s = self.addonSettings
            s[keyPath: keyPath] = value
            self.setAddonSettings(s)
        }
    }
}

/// Settings › Torrents & Debrid › Torrent Engine: how the libtorrent engine
/// streams (peers, buffering), uploads and caches, and where its server listens.
struct TorrentEngineSettingsPage: View {
    nonisolated static let title = "Torrent Engine"
    @Environment(AppModel.self) private var app
    @State private var cacheBytes: Int64?
    @State private var confirmClearCache = false

    private func setting<T>(_ keyPath: WritableKeyPath<AddonSettings, T>) -> Binding<T> {
        app.addonSetting(keyPath)
    }

    var body: some View {
        let settings = app.addonSettings
        SettingsForm(.torrents, subpage: Self.title) {
            Section {
                Stepper(value: setting(\.maxPeers), in: 20...200, step: 10) {
                    LabeledContent("Maximum Peers", value: "\(settings.maxPeers)")
                }
                .settingsRow("Maximum Peers")
                Stepper(value: setting(\.raceWidth), in: 1...5) {
                    LabeledContent("Torrents Tried at Once", value: "\(settings.raceWidth)")
                }
                .settingsRow("Torrents Tried at Once")
                SettingsPicker("Start Playing After", selection: setting(\.minimumPrebufferMB),
                               options: [1, 3, 5, 8].map { .init("\($0) MB", value: $0) })
                    .settingsRow("Start Playing After")
                SettingsPicker("Buffer at Most", selection: setting(\.maximumPrebufferMB),
                               options: [8, 16, 32, 64].map { .init("\($0) MB", value: $0) })
                    .settingsRow("Buffer at Most")
            } header: {
                Text("Streaming")
            } footer: {
                Text("Bluebox buffers about a minute of video, between these two sizes. Less starts sooner but may pause. Changes apply to the next stream.")
            }

            Section {
                SettingsPicker("Upload Limit", selection: setting(\.uploadLimitKBps), options: [
                    .init("Unlimited", value: nil), .init("1 MB/s", value: 1024), .init("500 KB/s", value: 500),
                    .init("100 KB/s", value: 100), .init("Don't Upload", value: 0),
                ])
                .settingsRow("Upload Limit")
                SettingsPicker("Keep Streams", selection: setting(\.streamCacheLimitBytes),
                               options: [.init("Don't Keep", value: Int64(0))]
                                   + [2, 5, 10, 25, 50].map { .init("\($0) GB", value: Int64($0) << 30) })
                    .settingsRow("Keep Streams")
                LabeledContent("Stream Cache", value: cacheBytes.map(ByteText.string) ?? "Calculating…")
                Button("Clear Stream Cache", role: .destructive) { confirmClearCache = true }
                    .disabled(app.activePlayer != nil || (cacheBytes ?? 0) == 0)
                    .settingsRow("Clear Stream Cache")
                    .confirmationDialog("Clear the stream cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                        Button("Clear Stream Cache", role: .destructive) { Task { await clearCache() } }
                    } message: {
                        Text("Kept streams are deleted. Watching them again downloads them again. Downloads aren't affected.")
                    }
            } header: {
                Text("Uploads and Cache")
            } footer: {
                Text(app.activePlayer != nil
                     ? "Close the player to clear the cache."
                     : "Kept streams replay without downloading again.")
            }

            Section {
                SettingsLink("Extra Trackers", value: settings.extraTrackers.isEmpty ? "None" : "\(settings.extraTrackers.count)") {
                    TrackersPage(trackers: setting(\.extraTrackers))
                }
                .settingsRow("Extra Trackers")
                SettingsPicker("Add-on Timeout", selection: setting(\.addonTimeoutSeconds),
                               options: [5, 10, 15, 20].map { .init("\($0) s", value: $0) })
                    .settingsRow("Add-on Timeout")
                CommitField(title: "Stream Server Port", value: String(settings.streamingPort), prompt: "8888", numeric: true) { text in
                    guard let port = Int(text), (1024...65535).contains(port) else { return false }
                    setting(\.streamingPort).wrappedValue = port
                    return true
                }
                .settingsRow("Stream Server Port")
                if settings.addons.contains(where: { $0.preset == .stremthru }) {
                    CommitField(title: "StremThru Server", value: settings.stremthruHost, prompt: AddonPreset.defaultStremthruHost, numeric: false) { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        setting(\.stremthruHost).wrappedValue = trimmed.isEmpty ? AddonPreset.defaultStremthruHost : trimmed
                        return true
                    }
                    .settingsRow("StremThru Server")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The stream server only listens on this device. Change the StremThru server only if you host your own.")
            }
        }
        .task(id: app.activePlayer == nil) { await refreshCacheSize() }
    }

    private func refreshCacheSize() async {
        cacheBytes = await Task.detached { StreamCache.totalBytes() }.value
    }

    private func clearCache() async {
        await Task.detached { StreamCache.clear() }.value
        await refreshCacheSize()
    }
}

/// A text field that saves on Return or when you leave it, and shows an error for bad input.
struct CommitField: View {
    let title: String
    let value: String
    let prompt: String
    let numeric: Bool
    let commit: (String) -> Bool
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(numeric ? .numberPad : .URL)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .onSubmit(save)
                .foregroundStyle(invalid ? Palette.warning : Palette.textSecondary)
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        guard text != value else { invalid = false; return }
        invalid = !commit(text)
        if invalid { text = value }
    }
}

private struct HiddenQualitiesPage: View {
    @Binding var hidden: Set<QualityFilter>

    var body: some View {
        SettingsForm(title: "Hidden Qualities") {
            Section {
                ForEach(QualityFilter.offered) { quality in
                    Toggle(quality.title, isOn: Binding {
                        hidden.contains(quality)
                    } set: { on in
                        if on { hidden.insert(quality) } else { hidden.remove(quality) }
                    })
                }
            } footer: {
                Text("Releases of these qualities aren't offered or picked automatically, whichever add-on finds them. CAM rips and screeners are hidden by default.")
            }
        }
    }
}

private struct TrackersPage: View {
    @Binding var trackers: [String]
    @State private var text = ""

    var body: some View {
        SettingsForm(title: "Extra Trackers") {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .scrollContentBackground(.hidden)
            } footer: {
                Text("One tracker URL per line, such as udp://tracker.example.org:1337/announce. They're added to every torrent alongside the built-in list, which can help find peers for a quiet torrent.")
            }
        }
        .onAppear { text = trackers.joined(separator: "\n") }
        .onDisappear {
            trackers = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { URL(string: $0)?.scheme != nil }
        }
    }
}
