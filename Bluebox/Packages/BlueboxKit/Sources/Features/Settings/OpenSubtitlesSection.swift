import DesignSystem
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
