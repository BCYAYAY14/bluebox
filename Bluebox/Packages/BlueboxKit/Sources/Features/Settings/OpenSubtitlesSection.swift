import DesignSystem
import Metadata
import SwiftUI

// Settings › Subtitles' online search: one section per site that needs a
// key (OpenSubtitles, Subdl), holding its key, sign-in, removal and its
// switches together, then the sites that need nothing. Keys are entered with
// `SettingsKeyField`, like Catalog's: checked and saved as soon as one is
// pasted or Return is pressed.

/// OpenSubtitles: the key, the optional sign-in, Search Online and Search Automatically.
struct OpenSubtitlesSection: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keyError: String?
    @State private var message: String?
    @State private var working = false

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            if app.hasOpenSubtitlesKey {
                LabeledContent("OpenSubtitles API Key", value: app.openSubtitlesSignedIn ? "Connected · Signed In" : "Connected")
                    .settingsRow("OpenSubtitles API Key")
                if app.openSubtitlesSignedIn {
                    Button("Sign Out of OpenSubtitles") { Task { await app.signOutOfOpenSubtitles() } }
                } else {
                    TextField("OpenSubtitles username (optional)", text: $username)
                        .textContentType(.username).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password).textContentType(.password)
                    Button(working ? "Signing In…" : "Sign In") { Task { await signIn() } }
                        .disabled(username.isEmpty || password.isEmpty || working)
                }
                if let message { Text(ui: message).font(.footnote).foregroundStyle(Palette.warning) }
                Button("Remove Key", role: .destructive) { app.removeOpenSubtitlesKey(); message = nil }
            } else {
                SettingsKeyField(label: "OpenSubtitles API key", text: $key, working: working, error: keyError) {
                    await saveKey()
                }
                .settingsRow("OpenSubtitles API Key")
            }
            SubtitleSiteToggle(site: .openSubtitles, title: "Include in Search Online")
            Toggle("Search Automatically", isOn: $settings.autoSearchSubtitles)
                .disabled(!app.hasOpenSubtitlesKey)
                .settingsRow("Search Automatically")
        } header: {
            Text("OpenSubtitles")
        } footer: {
            Text("Create a free API consumer at opensubtitles.com › Profile › API consumers and paste its key here. Signing in is optional and raises the daily limit. Keys stay in your Keychain.")
            Text(autoSearchFooter)
        }
    }

    private var autoSearchFooter: String {
        if !app.hasOpenSubtitlesKey { return "Search Automatically needs the key." }
        if app.subtitleStyle.preferredLanguage == nil { return "Search Automatically looks for your subtitle language: choose one on the Language page first." }
        return "Search Automatically: when a video has nothing in your language, Bluebox adds the best match from OpenSubtitles. Each counts toward your daily limit."
    }

    private func saveKey() async {
        guard !working, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await app.saveOpenSubtitlesKey(key)
            key = ""
            keyError = nil
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            try await app.signInToOpenSubtitles(username: username, password: password)
            password = ""
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Subdl: the key, removing it, and Search Online.
struct SubdlSection: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var keyError: String?
    @State private var working = false

    var body: some View {
        Section {
            if app.hasSubdlKey {
                LabeledContent("Subdl API Key", value: "Connected")
                    .settingsRow("Subdl API Key")
                Button("Remove Key", role: .destructive) { app.removeSubdlKey() }
            } else {
                SettingsKeyField(label: "Subdl API key", text: $key, working: working, error: keyError) {
                    await saveKey()
                }
                .settingsRow("Subdl API Key")
            }
            SubtitleSiteToggle(site: .subdl, title: "Include in Search Online")
        } header: {
            Text("Subdl")
        } footer: {
            Text("Get a free API key at subdl.com › Panel › API. It stays in your Keychain.")
        }
    }

    private func saveKey() async {
        guard !working, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        defer { working = false }
        do {
            try await app.saveSubdlKey(key)
            key = ""
            keyError = nil
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Search Online's sites that need no key, and what Search Online does.
struct SubtitleSitesSection: View {
    var body: some View {
        Section {
            SubtitleSiteToggle(site: .podnapisi)
                .settingsRow("Search Online Sites")
            SubtitleSiteToggle(site: .jellyfin)
        } header: {
            Text("Search Online")
        } footer: {
            Text("Search Online in the player asks every site that's on at once, OpenSubtitles and Subdl above included, and shows one list with the best match for the release first.")
        }
    }
}

/// One site's Search Online switch, with what it still needs under its name.
private struct SubtitleSiteToggle: View {
    @Environment(AppModel.self) private var app
    let site: SubtitleSite
    /// Inside the site's own section the switch says what it's for; in the list, the site's name.
    var title: String?

    var body: some View {
        Toggle(isOn: Binding(get: { app.enabledSubtitleSites.contains(site) },
                             set: { app.setSubtitleSite(site, enabled: $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                if let title { Text(ui: title) } else { Text(site.title) }
                if let note { Text(ui: note).font(.caption).foregroundStyle(Palette.textSecondary) }
            }
        }
    }

    private var note: String? {
        switch site {
        case .openSubtitles: app.hasOpenSubtitlesKey ? nil : "Needs the key"
        case .subdl: app.hasSubdlKey ? nil : "Needs the key"
        case .podnapisi: nil
        case .jellyfin: app.canAsk(.jellyfin) || !app.enabledSubtitleSites.contains(.jellyfin) ? nil : "Add a Jellyfin server in Sources"
        }
    }
}
