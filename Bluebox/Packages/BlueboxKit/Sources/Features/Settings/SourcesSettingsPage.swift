import DesignSystem
import Domain
import MediaSources
import SwiftUI
import Torrent
import UniformTypeIdentifiers

struct SourcesSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var sources: [SourceRow] = []
    @State private var links: [DirectURLSource.Item] = []
    @State private var importingFolder = false
    @State private var addingLink = false
    @State private var addingServer = false
    @State private var confirmRemoveServer: SourceRow?

    struct SourceRow: Identifiable {
        let id: SourceID
        let name: String
        let kind: SourceKind
        let capabilities: SourceCapabilities
        var enabled: Bool
        var health: SourceHealth?
        /// Sources this row also switches: your own torrents and add-on releases share one "Torrents" row.
        var merged: [SourceID] = []
    }

    /// "Touch and hold" on iPhone and iPad, "Control-click" on Mac.
    static var holdGesture: String {
        #if os(iOS)
        "Touch and hold"
        #else
        "Control-click"
        #endif
    }

    var body: some View {
        SettingsForm(.sources) {
            Section {
                ForEach($sources) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { row.enabled }, set: { on in
                            row.enabled = on
                            Task { for id in [row.id] + row.merged { await app.setSourceEnabled(id, on) } }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(capabilitySummary(row)).font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        if let h = row.health {
                            Label(h.message, systemImage: h.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(h.ok ? Palette.brand : Palette.warning)
                        }
                    }
                    .settingsRow(row.name)  // "Open Movies" and other sources by name
                    // A folder comes back with Undo; a server needs signing in again, so it asks first.
                    .contextMenu {
                        Button("Test Connection") { Task { await test(row.id) } }
                        if row.kind == .localFolder {
                            Button("Remove", role: .destructive) { removeFolder(row) }
                        } else if row.kind == .jellyfin {
                            Button("Remove…", role: .destructive) { confirmRemoveServer = row }
                        }
                    }
                }
                Button("Add Folder…") { importingFolder = true }
                    .settingsRow("Add Folder")
                Button("Add Jellyfin Server…") { addingServer = true }
                    .accessibilityIdentifier("addJellyfinButton")
                    .settingsRow("Add Jellyfin Server")
                Button("Test All Sources") { Task { for s in sources { await test(s.id) } } }
                    .settingsRow("Test All Sources")
            } header: {
                Text("Sources")
            } footer: {
                Text("Bluebox plays from sources you're allowed to use. Add-ons and debrid are in Torrents & Debrid. \(Self.holdGesture) a source to test or remove it.")
            }

            Section {
                ForEach(links, id: \.url) { item in
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text(Redactor.redact(item.url)).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    .contextMenu { Button("Remove", role: .destructive) { removeLink(item) } }
                }
                Button("Add Link…") { addingLink = true }
                    .settingsRow("Add Link")
            } header: {
                Text("Direct Links")
            } footer: {
                Text("Video files or HLS streams you're allowed to watch. \(Self.holdGesture) a link to remove it.")
            }

            Section {
                if let name = app.debridLibraryName {
                    SettingsLink("Open \(name) Library") { DebridLibraryView() }
                        .settingsRow("Debrid Library")
                } else {
                    // Not set up: the way to set it up, rather than a disabled row.
                    SettingsLink("Set Up a Debrid Service") { TorrentsSettingsPage() }
                        .settingsRow("Debrid Library")
                }
            } header: {
                Text("Debrid Library")
            } footer: {
                Text(app.debridLibraryName == nil
                     ? "With a debrid service, everything you've saved there plays here too."
                     : "Everything saved in your \(app.debridLibraryName ?? "debrid") account, ready to play.")
            }

            TorrentsSection()
        }
        .task(id: app.sourcesRevision) { await loadSources() }
        .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await app.addLocalFolder(url) }
                catch { app.alert = AppAlert(title: "Couldn't add folder", message: UserFacingError.message(for: error)) }
            }
        }
        .sheet(isPresented: $addingLink) { AddLinkSheet { await loadSources() } }
        .sheet(isPresented: $addingServer) { AddJellyfinSheet() }
        .confirmationDialog("Remove \(confirmRemoveServer?.name ?? "this server")?",
                            isPresented: Binding(get: { confirmRemoveServer != nil }, set: { if !$0 { confirmRemoveServer = nil } }),
                            titleVisibility: .visible, presenting: confirmRemoveServer) { row in
            Button("Remove", role: .destructive) { Task { await app.removeSource(row.id); await loadSources() } }
        } message: { _ in
            Text("Bluebox forgets its sign-in. To add it again, you'll need your username and password.")
        }
    }

    /// Removes a folder at once, with Undo: the folder itself isn't touched.
    private func removeFolder(_ row: SourceRow) {
        let config = app.sourceConfigurations.first { $0.id == row.id }
        Task {
            await app.removeSource(row.id)
            await loadSources()
            app.showToast(AppToast("Removed \(row.name)", actionTitle: "Undo") { [app] in
                guard let config else { return }
                Task { await app.restoreLocalFolder(config) }
            })
        }
    }

    /// Removes a direct link at once, with Undo.
    private func removeLink(_ item: DirectURLSource.Item) {
        Task {
            await app.removeDirectLink(item.url)
            await loadSources()
            app.showToast(AppToast("Removed \(item.title)", actionTitle: "Undo") { [app] in
                Task { try? await app.addDirectLink(url: item.url, title: item.title, matching: item.mediaKey) }
            })
        }
    }

    private func capabilitySummary(_ row: SourceRow) -> String {
        var parts: [String] = []
        if row.capabilities.contains(.play) { parts.append("Streams") }
        if row.capabilities.contains(.download) { parts.append("Downloads") }
        if row.capabilities.contains(.externalSubtitles) { parts.append("Subtitles") }
        return parts.joined(separator: " · ")
    }

    private func loadSources() async {
        var rows: [SourceRow] = []
        for s in await app.registry.all() {
            // The debrid library only means something once a debrid service is set up.
            if s.id == SidebarSource.debridLibraryID && app.debridLibraryName == nil { continue }
            rows.append(SourceRow(id: s.id, name: s.displayName, kind: s.kind, capabilities: s.capabilities,
                                  enabled: await app.registry.isEnabled(s.id)))
        }
        sources = Self.mergingTorrents(rows)
        links = await app.directLinkItems()
    }

    /// Your own torrents and add-on releases ("Torrents & Debrid") are both
    /// torrents to the user, so they share one "Torrents" row and switch together.
    static func mergingTorrents(_ rows: [SourceRow]) -> [SourceRow] {
        guard let mine = rows.firstIndex(where: { $0.kind == .torrent }),
              let addons = rows.firstIndex(where: { $0.kind == .addons }) else { return rows }
        var out = rows
        let other = rows[addons]
        out[mine] = SourceRow(id: rows[mine].id, name: "Torrents", kind: .torrent,
                              capabilities: rows[mine].capabilities.union(other.capabilities),
                              enabled: rows[mine].enabled || other.enabled, merged: [other.id])
        out.remove(at: addons)
        return out
    }

    private func test(_ id: SourceID) async {
        guard let source = await app.registry.source(id) else { return }
        let health = await source.testConnection()
        if let i = sources.firstIndex(where: { $0.id == id }) { sources[i].health = health }
    }
}

extension AppModel {
    /// Undo for removing a folder source: adds the same folder back from its bookmark.
    func restoreLocalFolder(_ config: SourceConfiguration) async {
        guard let b64 = config.settings["bookmark"], let data = Data(base64Encoded: b64) else { return }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        do { try await addLocalFolder(url) } catch {
            alert = AppAlert(title: "Couldn't add the folder back", message: UserFacingError.message(for: error))
        }
    }
}

struct TorrentsSection: View {
    @Environment(AppModel.self) private var app
    @State private var items: [TorrentSource.Item] = []
    @State private var statuses: [InfoHash: TorrentStatus] = [:]
    @State private var adding = false
    /// Removing deletes the downloaded files, which Undo can't bring back, so it asks first.
    @State private var confirmRemove: TorrentSource.Item?

    var body: some View {
        Section {
            ForEach(items, id: \.infoHash) { item in
                TorrentRow(item: item, status: statuses[item.infoHash])
                    .contextMenu { Button("Remove and Delete Files…", role: .destructive) { confirmRemove = item } }
            }
            // The sheet and polling hang off this row: SettingsForm reads sections
            // by their content, so the Section itself carries no modifiers.
            Button("Add Torrent…") { adding = true }
                .accessibilityIdentifier("addTorrentButton")
                .settingsRow("Add Torrent")
                .sheet(isPresented: $adding) { AddTorrentSheet { await load() } }
                .confirmationDialog("Remove “\(confirmRemove?.title ?? "this torrent")”?",
                                    isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                    titleVisibility: .visible, presenting: confirmRemove) { item in
                    Button("Remove and Delete Files", role: .destructive) { Task { await remove(item) } }
                } message: { _ in
                    Text("Its downloaded files are deleted from this device.")
                }
                .task(id: app.sourcesRevision) {
                    await load()
                    while !Task.isCancelled {
                        for item in items { statuses[item.infoHash] = await app.torrentStatus(item.infoHash) }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        } header: {
            Text("Your Torrents")
        } footer: {
            Text("A magnet link or .torrent file for something you have the right to watch. It downloads in order, so you can start watching at once. Bluebox never searches for torrents.")
        }
    }

    private func load() async { items = await app.torrentItems() }

    private func remove(_ item: TorrentSource.Item) async {
        await app.removeTorrent(item.infoHash)
        await load()
    }
}

struct TorrentRow: View {
    let item: TorrentSource.Item
    let status: TorrentStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).lineLimit(1)
            if let status {
                if case .downloading = status.phase { ProgressView(value: status.fraction).tint(Palette.brand) }
                Text(detail(status)).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ s: TorrentStatus) -> String {
        let size = ByteCountFormatter.string(fromByteCount: s.wantedBytes, countStyle: .file)
        let matched = item.matches.isEmpty ? "Not matched to the catalog" : "\(item.matches.count) matched"
        switch s.phase {
        case .fetchingMetadata: return "Getting file list…"
        case .complete: return "Downloaded · \(size) · \(matched)"
        case .paused: return "Paused · \(Int(s.fraction * 100))% of \(size) · \(matched)"
        case .failed(let reason): return reason
        case .downloading:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(s.bytesPerSecond), countStyle: .file)
            return "\(Int(s.fraction * 100))% of \(size) · \(s.peers) peer\(s.peers == 1 ? "" : "s") · \(rate)/s · \(matched)"
        }
    }
}

struct AddTorrentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onDone: () async -> Void
    @State private var magnet = ""
    @State private var error: String?
    @State private var working = false
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                    .lineLimit(1...4)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("magnetField")
                Button { picking = true } label: { Label("Choose a .torrent File…", systemImage: "doc") }
                if working {
                    HStack { ProgressView().controlSize(.small); Text("Getting the file list…").font(.footnote) }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.warning) }
                Text("Only add torrents you have the right to download and watch. Video files are matched to the catalog by name. MP4, MOV and M4V play while downloading.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await run { try await app.addTorrent(magnet: magnet) } } }
                        .disabled(magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
                guard case .success(let url) = result else { return }
                Task { await run { try await app.addTorrent(file: url) } }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .preferredColorScheme(.dark)
    }

    private func run(_ body: () async throws -> TorrentSource.Item) async {
        working = true; error = nil
        defer { working = false }
        do {
            _ = try await body()
            await onDone()
            dismiss()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

struct AddJellyfinSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://media.example.com", text: $server)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("jellyfinServerField")
                TextField("Username", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.warning) }
                Text("Bluebox signs in once and keeps only the server's access token, in your Keychain. Use https:// for servers outside your home network.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Jellyfin Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Signing In…" : "Sign In") { Task { await save() } }
                        .disabled(server.isEmpty || username.isEmpty || working)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .preferredColorScheme(.dark)
    }

    private func save() async {
        working = true; error = nil
        defer { working = false }
        do {
            try await app.addJellyfin(server: server, username: username, password: password)
            dismiss()
        } catch SourceError.unauthorized {
            error = "The server didn't accept that username and password."
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

struct AddLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onDone: () async -> Void
    @State private var urlText = ""
    @State private var title = ""
    @State private var match = true
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://…/movie.mp4", text: $urlText)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Title", text: $title)
                Toggle("Match to catalog by title", isOn: $match)
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.warning) }
                Text("Only add links you have the right to stream. MP4, MOV, M4V and HLS (.m3u8) are supported.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(urlText.isEmpty || title.isEmpty || saving)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .preferredColorScheme(.dark)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { error = "That isn't a valid URL."; return }
        var key: MediaKey?
        if match {
            key = await app.makeMatcher()(MediaNameParser.parse(filename: title))
        }
        do {
            try await app.addDirectLink(url: url, title: title, matching: key)
            await onDone()
            dismiss()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
