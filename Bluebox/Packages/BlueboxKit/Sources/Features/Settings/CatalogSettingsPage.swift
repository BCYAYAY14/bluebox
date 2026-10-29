import DesignSystem
import Domain
import Metadata
import SwiftUI

struct CatalogSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var tokenError: String?
    @State private var savingToken = false
    @State private var omdbKey = ""
    @State private var omdbError: String?
    @State private var savingOMDb = false

    var body: some View {
        SettingsForm(.catalog) {
            Section {
                LabeledContent("Catalog", value: catalogName)
                if app.hasTMDBCredential {
                    LabeledContent("TMDB Token", value: "Connected")
                        .settingsRow("TMDB Token")
                    Button("Remove Token", role: .destructive) { app.removeTMDBCredential(); tokenError = nil }
                } else {
                    // Saved and checked on Return or as soon as a token is pasted: no separate Save row.
                    SettingsKeyField(label: "TMDB read access token", text: $token, working: savingToken, error: tokenError) {
                        await saveToken()
                    }
                    .settingsRow("TMDB Token")
                    .accessibilityIdentifier("tmdbTokenField")
                }
            } header: {
                Text("Catalog")
            } footer: {
                Text(app.catalogMode == .cinemeta
                     ? "Browsing uses Cinemeta, which needs no key. A free TMDB token (themoviedb.org › Settings › API) adds richer artwork, cast and credits."
                     : "Get a free token at themoviedb.org › Settings › API. It stays in your Keychain and only goes to TMDB.")
            }

            Section {
                LabeledContent("Ratings", value: app.hasOMDbKey ? "IMDb, Rotten Tomatoes, Metacritic" : "Off")
                if app.hasOMDbKey {
                    LabeledContent("OMDb API Key", value: "Connected")
                        .settingsRow("OMDb API Key")
                    Button("Remove Key", role: .destructive) { app.removeOMDbKey(); omdbError = nil }
                } else {
                    SettingsKeyField(label: "OMDb API key", text: $omdbKey, working: savingOMDb, error: omdbError) {
                        await saveOMDbKey()
                    }
                    .settingsRow("OMDb API Key")
                    .accessibilityIdentifier("omdbKeyField")
                }
            } header: {
                Text("Ratings")
            } footer: {
                Text("A free key from omdbapi.com adds IMDb, Rotten Tomatoes and Metacritic scores to title pages. Keys stay in your Keychain.")
            }
        }
    }

    private var catalogName: String {
        switch app.catalogMode {
        case .live: "TMDB"
        case .cinemeta: "Cinemeta"
        case .sample: "Built-in Sample"
        }
    }

    private func saveOMDbKey() async {
        guard !savingOMDb, !omdbKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingOMDb = true
        defer { savingOMDb = false }
        do {
            try await app.saveOMDbKey(omdbKey)
            omdbKey = ""
            omdbError = nil
        } catch MetadataError.unauthorized {
            omdbError = "OMDb rejected that key. Check it, and make sure you activated it from the email OMDb sent."
        } catch {
            omdbError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveToken() async {
        guard !savingToken, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingToken = true
        defer { savingToken = false }
        do {
            try await app.saveTMDBCredential(token)
            token = ""
            tokenError = nil
        } catch {
            tokenError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// An API key or token field in the sign-in style: a tall box whose label
/// floats up, a paste button, and the check running as soon as a key is
/// pasted or Return is pressed, with a red error under the box.
struct SettingsKeyField: View {
    let label: String
    @Binding var text: String
    let working: Bool
    let error: String?
    let save: () async -> Void

    var body: some View {
        FloatingField(label: label, text: $text, secure: true, error: error, submitLabel: .done,
                          onSubmit: { Task { await save() } }) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    PasteButton(payloadType: String.self) { strings in
                        let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        Task { @MainActor in
                            text = pasted
                            await save()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .tint(Color.white.opacity(0.14))
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        .disabled(working)
        .accessibilityValue(working ? "Checking" : "")
        .padding(.vertical, Spacing.xs)
        // Pasting into the field (rather than with the button) saves too: a key arrives all at once.
        .onChange(of: text) { old, new in
            if new.count - old.count >= 6 { Task { await save() } }
        }
    }
}
