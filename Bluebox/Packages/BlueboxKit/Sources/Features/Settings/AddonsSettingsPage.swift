//
//  AddonsSettingsPage.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  manifest docs). Settings › Torrents & Debrid › Add-ons: your
//  add-ons with health dots, turning them on and off, the order they're
//  asked in, which of their catalogs are rows on Home, adding any Stremio
//  add-on by its link, and the presets.
//

import Addons
import DesignSystem
import Persistence
import SwiftUI

extension AppModel {
    /// Removes an add-on at once, with Undo in a toast that puts it back where it was.
    func removeAddonUndoably(_ addon: InstalledAddon) {
        let index = addonSettings.addons.firstIndex { $0.id == addon.id }
        let link = addonSettings.customLinks[addon.id]
        removeAddon(addon.id)
        showToast(AppToast("Removed \(addon.name)", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            var s = self.addonSettings
            guard !s.addons.contains(where: { $0.id == addon.id }) else { return }
            s.addons.insert(addon, at: min(index ?? s.addons.count, s.addons.count))
            if let link {
                try? self.secrets.write(link, for: SecretAccount.addonLink(addon.id))
                s.customLinks[addon.id] = link
            }
            self.setAddonSettings(s)
        })
    }
}

struct AddonsSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var health: [String: AddonHealth] = [:]
    @State private var link = ""
    @State private var adding = false
    @State private var addResult: (ok: Bool, message: String)?
    /// An add-on whose link is being pasted (it came from another device without it).
    @State private var linkFor: InstalledAddon?
    @State private var pastedLink = ""
    @State private var linkResult: (ok: Bool, message: String)?

    var body: some View {
        let settings = app.addonSettings
        SettingsForm(title: "Add-ons") {
            Section {
                if settings.addons.isEmpty {
                    Text("No add-ons. Add one below.").foregroundStyle(Palette.textSecondary)
                }
                ForEach(settings.addons) { addon in
                    if settings.needsLink(addon) {
                        Button { pastedLink = ""; linkFor = addon } label: {
                            HStack(spacing: Spacing.m) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(addon.name).foregroundStyle(Palette.textPrimary).lineLimit(1)
                                    Text("\(addon.hostLabel) · Its link isn't on this device").font(.caption)
                                        .foregroundStyle(Palette.textSecondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Text("Paste Link").foregroundStyle(Palette.brandBright)
                            }
                        }
                        .contextMenu { menu(addon) }
                        .accessibilityIdentifier("pasteAddonLink")
                    } else {
                        AddonSettingsRow(addon: addon, health: health[addon.id],
                                         isOn: Binding { addon.isEnabled } set: { app.setAddon(addon.id, enabled: $0) })
                            .contextMenu { menu(addon) }
                    }
                }
                if let linkResult { SettingsStatus(ok: linkResult.ok, message: linkResult.message) }
                if settings.addons.count > 1 {
                    SettingsLink("Order and Remove", value: nil) { AddonOrderPage() }
                        .settingsRow("Add-on Order")
                }
            } header: {
                Text("Your Add-ons")
            } footer: {
                Text((settings.addons.contains(where: settings.needsLink)
                      ? "Add-ons added by link keep their link in this device's Keychain, and it follows to your other devices only with Sync API Keys on (Settings › Account). "
                      : "") + "Every add-on that's on is asked at once; a slow one is skipped for a few minutes after repeated timeouts. When two releases are equally good, the add-on higher in the list wins.")
            }

            let withCatalogs = settings.addons.filter { !($0.catalogs ?? []).isEmpty }
            if !withCatalogs.isEmpty {
                Section {
                    ForEach(withCatalogs) { addon in
                        let catalogs = addon.catalogs ?? []
                        SettingsLink(addon.name, value: "\(catalogs.filter(\.isShown).count) of \(catalogs.count)") {
                            AddonCatalogsPage(addonID: addon.id)
                        }
                        .settingsRow("Add-on Catalogs on Home")
                    }
                } header: {
                    Text("Rows on Home")
                } footer: {
                    Text("Lists your add-ons publish, shown on Home after Bluebox's own rows. A new add-on's first few are on; turn on the ones you want. Titles without an IMDb or TMDB ID are left out.")
                }
            }

            Section {
                TextField("Add-on link", text: $link, prompt: Text("stremio://… or https://…/manifest.json"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { Task { await add() } }
                    .settingsRow("Add Add-on by Link")
                Button {
                    Task { await add() }
                } label: {
                    HStack {
                        Text(adding ? "Checking the Add-on…" : "Add Add-on")
                        if adding { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(adding || link.trimmingCharacters(in: .whitespaces).isEmpty)
                if let addResult { SettingsStatus(ok: addResult.ok, message: addResult.message) }
            } header: {
                Text("Add by Link")
            } footer: {
                Text("Paste the link an add-on's configure page gives you (Install, or Copy Link). Bluebox reads its manifest and adds it if it offers streams for movies or series. The link can contain your settings for that add-on, often a debrid key, so it's kept in the Keychain and only shown by its host.")
            }

            if !settings.availablePresets.isEmpty {
                Section {
                    ForEach(settings.availablePresets) { preset in
                        Button { app.addPreset(preset) } label: {
                            HStack(spacing: Spacing.m) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title).foregroundStyle(Palette.textPrimary)
                                    Text(preset.summary).font(.caption).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Palette.brandBright)
                            }
                        }
                        .accessibilityLabel("Add \(preset.title)")
                    }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("Presets are set up from your debrid service and release settings, so changing those updates them.")
                }
            }
        }
        .alert("Paste \(linkFor?.name ?? "the Add-on")'s Link", isPresented: Binding(get: { linkFor != nil }, set: { if !$0 { linkFor = nil } })) {
            TextField("Add-on link", text: $pastedLink)
                .autocorrectionDisabled()
            Button("Add Link") {
                guard let addon = linkFor else { return }
                let text = pastedLink
                Task {
                    do {
                        try await app.setAddonLink(addon.id, link: text)
                        linkResult = (true, "\(addon.name) is ready.")
                    } catch {
                        linkResult = (false, (error as? LocalizedError)?.errorDescription ?? UserFacingError.message(for: error, context: .addons))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copy it from the add-on's configure page, or from a device that has it. It's kept in this device's Keychain.")
        }
        .task {
            // Health changes as searches run; refresh while the page is open.
            while !Task.isCancelled {
                health = await app.addonHealth()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private func menu(_ addon: InstalledAddon) -> some View {
        Button { app.setAddon(addon.id, enabled: !addon.isEnabled) } label: {
            Label(addon.isEnabled ? "Turn Off" : "Turn On", systemImage: addon.isEnabled ? "pause.circle" : "play.circle")
        }
        if health[addon.id]?.state() == .skipped || health[addon.id]?.state() == .failing {
            Button { Task { await app.retryAddon(addon.id); health = await app.addonHealth() } } label: {
                Label("Try Again Now", systemImage: "arrow.clockwise")
            }
        }
        Button(role: .destructive) { app.removeAddonUndoably(addon) } label: { Label("Remove", systemImage: "trash") }
    }

    private func add() async {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        addResult = nil
        defer { adding = false }
        do {
            let addon = try await app.addAddon(link: text)
            link = ""
            addResult = (true, "Added \(addon.name).")
        } catch {
            addResult = (false, (error as? LocalizedError)?.errorDescription ?? UserFacingError.message(for: error, context: .addons))
        }
    }
}

/// One add-on: a health dot, its name, where it lives and how it's been answering, and a switch.
struct AddonSettingsRow: View {
    let addon: InstalledAddon
    let health: AddonHealth?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.m) {
                Circle()
                    .fill(Self.color(health?.state() ?? .unknown, enabled: addon.isEnabled))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(addon.name).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
            }
        }
        .accessibilityValue(addon.isEnabled ? (health?.summary() ?? "Not used yet") : "Off")
    }

    private var subtitle: String {
        var parts = [addon.hostLabel]
        if addon.preset?.requiresDebrid == true { parts.append("Debrid only") }
        if addon.catalogsOnly == true { parts.append("Catalogs only") }
        if addon.isEnabled, let health { parts.append(health.summary()) }
        return parts.joined(separator: " · ")
    }

    static func color(_ state: AddonHealth.State, enabled: Bool) -> Color {
        guard enabled else { return Palette.textTertiary.opacity(0.5) }
        return switch state {
        case .unknown: Palette.textTertiary
        case .healthy: SwarmHealth.good
        case .slow: SwarmHealth.fair
        case .failing, .skipped: SwarmHealth.poor
        }
    }
}

/// Settings › Torrents & Debrid › Add-ons › (an add-on): a switch for each
/// of its catalogs, and drag to set their order on Home. The names are the
/// add-on's, shown as they are.
private struct AddonCatalogsPage: View {
    @Environment(AppModel.self) private var app
    let addonID: String

    var body: some View {
        let addon = app.addonSettings.addons.first { $0.id == addonID }
        List {
            Section {
                ForEach(addon?.catalogs ?? []) { catalog in
                    Toggle(isOn: Binding { catalog.isShown } set: { app.setAddonCatalog(catalog.id, of: addonID, shown: $0) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: catalog.name).lineLimit(1)
                            Text(Self.kind(catalog)).font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .settingsRow("Add-on Catalogs on Home")
                    .listRowBackground(Palette.background)
                }
                .onMove { from, to in app.moveAddonCatalogs(of: addonID, from: from, to: to) }
            } footer: {
                Text("Turned-on catalogs are rows on Home, in this order. Drag to reorder.")
            }
        }
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .blueboxScreen()
        .navigationTitle(addon?.name ?? "")
    }

    private static func kind(_ catalog: AddonCatalog) -> LocalizedStringKey {
        switch catalog.type {
        case "movie": "Movies"
        case "anime": "Anime"
        default: "Series"
        }
    }
}

/// Settings › Torrents & Debrid › Add-ons › Order and Remove: drag to
/// reorder, delete to remove.
private struct AddonOrderPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                ForEach(app.addonSettings.addons) { addon in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(addon.name)
                            Text(addon.hostLabel).font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        if !addon.isEnabled { Text("Off").font(.caption).foregroundStyle(Palette.textTertiary) }
                    }
                    .listRowBackground(Palette.background)
                }
                .onMove { from, to in app.moveAddons(from: from, to: to) }
                .onDelete { offsets in
                    for i in offsets.sorted(by: >) where app.addonSettings.addons.indices.contains(i) {
                        app.removeAddonUndoably(app.addonSettings.addons[i])
                    }
                }
            } footer: {
                Text("Drag to reorder. Releases come from every add-on that's on; the order breaks ties between equally good releases.")
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .blueboxScreen()
        .navigationTitle("Add-on Order")
    }
}
