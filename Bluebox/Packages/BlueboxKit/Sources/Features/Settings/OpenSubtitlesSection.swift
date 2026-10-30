import DesignSystem
import Metadata
import SwiftUI

struct OpenSubtitlesSection: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Section {
            if app.hasOpenSubtitlesKey {
                LabeledContent("Subtitle Search", value: app.openSubtitlesSignedIn ? "On · signed in" : "On")
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
                    Button(working ? "Signing In…" : "Sign In") { Task { await run { try await app.signInToOpenSubtitles(username: username, password: password); password = "" } } }
                        .disabled(username.isEmpty || password.isEmpty || working)
                }
                Button("Remove Key", role: .destructive) { app.removeOpenSubtitlesKey() }
            } else {
                SecureField("OpenSubtitles API Key", text: $key).textContentType(.password)
                    .settingsRow("OpenSubtitles API Key")
                Button(working ? "Checking…" : "Save Key") { Task { await run { try await app.saveOpenSubtitlesKey(key); key = "" } } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(Palette.warning) }
        } header: {
            Text("Subtitle Search")
        } footer: {
            Text("Create a free API consumer at opensubtitles.com › Profile › API consumers and paste its key here. Signing in is optional and raises the daily limit. Keys stay in your Keychain.")
        }
    }

    private func run(_ body: () async throws -> Void) async {
        working = true; message = nil
        defer { working = false }
        do { try await body() } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

/// Search Online's sites: each on or off, and Subdl's key.
struct SubtitleSitesSection: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Section {
            ForEach(SubtitleSite.allCases) { site in
                Toggle(isOn: Binding(get: { app.enabledSubtitleSites.contains(site) },
                                     set: { app.setSubtitleSite(site, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.title)
                        if let note = note(site) { Text(note).font(.caption).foregroundStyle(Palette.textSecondary) }
                    }
                }
            }
            .settingsRow("Search Online Sites")
            if app.hasSubdlKey {
                Button("Remove Subdl Key", role: .destructive) { app.removeSubdlKey() }
            } else {
                SecureField("Subdl API Key", text: $key).textContentType(.password)
                    .settingsRow("Subdl API Key")
                Button(working ? "Checking…" : "Save Subdl Key") { Task { await saveKey() } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(Palette.warning) }
        } header: {
            Text("Search Online")
        } footer: {
            Text("Search Online asks every site that's on at once and shows one list, the best match for the release first. Subdl needs a free API key from subdl.com › Panel › API.")
        }
    }

    private func note(_ site: SubtitleSite) -> String? {
        switch site {
        case .openSubtitles: app.hasOpenSubtitlesKey ? nil : "Needs the API key above"
        case .subdl: app.hasSubdlKey ? nil : "Needs an API key"
        case .podnapisi: nil
        case .jellyfin: app.canAsk(.jellyfin) || !app.enabledSubtitleSites.contains(.jellyfin) ? nil : "Add a Jellyfin server in Sources"
        }
    }

    private func saveKey() async {
        working = true; message = nil
        defer { working = false }
        do { try await app.saveSubdlKey(key); key = "" }
        catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}
